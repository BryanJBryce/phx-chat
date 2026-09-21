defmodule AppWeb.ChatMountTest do
  use AppWeb.ConnCase
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias App.Chat
  alias App.Chat.{Message, Room, User}
  alias App.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @tag :unboxed
  test "a commit after the connected history SELECT is delivered, and snapshot overlap is deduplicated" do
    existing_room = Repo.get_by(Room, slug: Chat.default_room_slug())
    room = Chat.ensure_default_room!()

    conn =
      post(build_conn(), ~p"/join", user: %{name: "Mount #{System.unique_integer([:positive])}"})

    user = Chat.get_user(get_session(conn, :user_id))

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from m in Message, where: m.user_id == ^user.id)
        Repo.delete!(Repo.get!(User, user.id))
        if is_nil(existing_room), do: Repo.delete!(Repo.get!(Room, room.id))
      end)
    end)

    # Complete disconnected rendering before installing a barrier on the connected SELECT.
    conn = conn |> recycle() |> get(~p"/")

    {:ok, view, message, snapshot_count} =
      mount_during(conn, fn ->
        Chat.create_message(room, user, %{body: "Committed during mount"})
      end)

    assert snapshot_count == 0
    assert has_element?(view, "#messages-#{message.id}", "Committed during mount")
    GenServer.stop(view.pid, :normal)

    conn = build_conn() |> init_test_session(user_id: user.id) |> get(~p"/")

    {:ok, overlapping, _, snapshot_count} =
      mount_during(conn, fn ->
        Phoenix.PubSub.broadcast(
          App.PubSub,
          Chat.messages_topic(room.slug),
          {:message_created, message}
        )

        {:ok, message}
      end)

    assert snapshot_count == 1

    ids =
      overlapping
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#messages [data-message-id]")
      |> LazyHTML.attribute("data-message-id")

    assert ids == [message.id]
  end

  defp mount_during(conn, operation) do
    parent = self()
    barrier = make_ref()

    writer =
      start_supervised!(%{
        id: barrier,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 {:snapshot, query_pid, count} ->
                   # A separate checked-out connection commits while the SELECT result is held.
                   result = Sandbox.unboxed_run(Repo, operation)
                   send(parent, {:committed, barrier, result, count})
                   send(query_pid, {:resume, barrier})
               after
                 2000 -> raise "connected history query did not reach the barrier"
               end
             end
           ]},
        restart: :temporary
      })

    :ok =
      :telemetry.attach(barrier, [:app, :repo, :query], &__MODULE__.pause_snapshot/4, %{
        barrier: barrier,
        writer: writer,
        parent: parent
      })

    on_exit(fn -> :telemetry.detach(barrier) end)

    try do
      {:ok, view, _} = live(conn)
      assert_receive {:committed, ^barrier, {:ok, message}, count}, 2000
      {:ok, view, message, count}
    after
      :telemetry.detach(barrier)
    end
  end

  # Telemetry runs after Postgres returned this SELECT, before Repo hands its result to mount.
  def pause_snapshot(_event, _measurements, metadata, config) do
    if metadata.source == "messages" and String.starts_with?(metadata.query, "SELECT") and
         self() != config.parent and not Process.get(config.barrier, false) do
      Process.put(config.barrier, true)
      {:ok, result} = metadata.result
      send(config.writer, {:snapshot, self(), result.num_rows})

      receive do
        {:resume, barrier} when barrier == config.barrier -> :ok
      after
        2000 -> raise "independent writer did not commit"
      end
    end
  end
end
