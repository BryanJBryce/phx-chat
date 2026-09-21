defmodule AppWeb.ChatIdentityTest do
  use AppWeb.ConnCase
  import Phoenix.LiveViewTest

  alias App.Chat
  alias AppWeb.Presence

  setup do
    Chat.ensure_default_room!()
    :ok
  end

  test "join validates, writes the signed session, and reuses the identity on refresh", %{
    conn: conn
  } do
    {:ok, visitor, _} = live(conn, ~p"/")
    assert has_element?(visitor, "#join-form")
    refute has_element?(visitor, "#user_name[aria-invalid=true]")
    visitor |> form("#join-form", user: %{name: "  "}) |> render_submit()
    assert has_element?(visitor, "#join-form", "can't be blank")

    assert has_element?(
             visitor,
             "#user_name[aria-invalid=true][aria-describedby=user_name-errors]"
           )

    assert has_element?(visitor, "#user_name-errors", "can't be blank")

    join_form = form(visitor, "#join-form", user: %{name: "  Alice  "})
    render_submit(join_form)
    joined_conn = follow_trigger_action(join_form, conn)
    assert redirected_to(joined_conn) == ~p"/"
    {:ok, joined, _} = live(recycle(joined_conn), ~p"/")
    assert has_element?(joined, "#current-user", "Alice")
    refute has_element?(joined, "#join-form")

    reused_conn = post(build_conn(), ~p"/join", user: %{name: "aLiCe"})
    assert get_session(reused_conn, :user_id) == get_session(joined_conn, :user_id)
    {:ok, refreshed, _} = live(recycle(joined_conn), ~p"/")
    assert has_element?(refreshed, "#current-user", "Alice")

    invalid = post(build_conn(), ~p"/join", user: %{name: "\n\t"})
    document = invalid |> html_response(422) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#join-form") |> LazyHTML.text() =~ "can't be blank"
    assert [_user] = Chat.list_users()
  end

  test "visitors see all users and a user stays online until their last connection exits", %{
    conn: conn
  } do
    Process.flag(:trap_exit, true)
    {:ok, offline} = Chat.get_or_create_user(%{name: "Offline person"})
    topic = Chat.presence_topic(Chat.default_room_slug())
    Phoenix.PubSub.subscribe(App.PubSub, topic)
    {:ok, visitor, _} = live(conn, ~p"/")
    assert Presence.list(topic) == %{}
    assert has_element?(visitor, "#users-#{offline.id} [data-status=offline]")

    joined_conn = post(build_conn(), ~p"/join", user: %{name: "Alice"})
    user_id = get_session(joined_conn, :user_id)
    assert has_element?(visitor, "#users-#{user_id} [data-status=offline]")
    {:ok, first, _} = live(recycle(joined_conn), ~p"/")
    await_presence(user_id, :joins)
    assert has_element?(visitor, "#users-#{user_id} [data-status=online]")

    {:ok, second, _} = live(recycle(joined_conn), ~p"/")
    await_presence(user_id, :joins)
    assert [_, _] = Presence.list(topic)[user_id].metas

    stop_view(first, :shutdown)
    await_presence(user_id, :leaves)
    assert has_element?(visitor, "#users-#{user_id} [data-status=online]")
    assert [_] = Presence.list(topic)[user_id].metas

    stop_view(second, :kill)
    await_presence(user_id, :leaves)
    assert has_element?(visitor, "#users-#{user_id} [data-status=offline]")
    assert has_element?(visitor, "#users-#{offline.id} [data-status=offline]")
    assert Presence.list(topic) == %{}
  end

  defp await_presence(id, event) do
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff", payload: payload}, 1000
    assert Map.has_key?(Map.fetch!(payload, event), id)
  end

  defp stop_view(view, reason) do
    Process.unlink(view.pid)
    ref = Process.monitor(view.pid)
    Process.exit(view.pid, reason)
    expected = if reason == :kill, do: :killed, else: reason
    assert_receive {:DOWN, ^ref, :process, _, ^expected}
  end
end
