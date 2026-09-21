defmodule AppWeb.ChatMessagesTest do
  use AppWeb.ConnCase
  import Phoenix.LiveViewTest

  alias App.Chat
  alias App.Chat.{Message, Room}
  alias App.Repo

  setup do
    %{room: Chat.ensure_default_room!()}
  end

  test "independent participants receive persisted messages with the server-held sender", %{
    room: room
  } do
    alice_conn = post(build_conn(), ~p"/join", user: %{name: "Alice"})
    bob_conn = post(build_conn(), ~p"/join", user: %{name: "Bob"})
    {:ok, alice, _} = live(recycle(alice_conn), ~p"/")
    {:ok, bob, _} = live(recycle(bob_conn), ~p"/")
    {:ok, visitor, _} = live(build_conn(), ~p"/")
    assert message_ids(alice) == []
    assert message_ids(bob) == []

    assert has_element?(
             bob,
             "#message-announcement[role=status][aria-live=polite][aria-atomic=true]"
           )

    assert announcement_text(bob) == ""

    alice |> form("#message-form", message: %{body: " \n "}) |> render_submit()
    assert has_element?(alice, "#message-form", "can't be blank")
    assert Chat.list_messages(room) == []

    # Raw events exercise a hostile client that bypasses the available form fields.
    render_submit(visitor, "send_message", %{"message" => %{"body" => "Visitor spoof"}})
    assert has_element?(visitor, "#join-form", "Join before sending a message")
    refute has_element?(visitor, "#message-history")
    assert Chat.list_messages(room) == []

    alice |> form("#message-form", message: %{body: "Hello\nBob"}) |> render_submit()
    [first] = Chat.list_messages(room)
    assert first.user_id == get_session(alice_conn, :user_id)
    assert message_ids(alice) == [first.id]
    assert message_ids(bob) == [first.id]
    assert has_element?(bob, "#messages-#{first.id}", "Alice")
    assert has_element?(bob, "#messages-#{first.id} time[datetime]")
    assert has_element?(bob, "#message-announcement", "1 new message. Total messages: 1.")

    render_submit(bob, "send_message", %{
      "message" => %{
        "body" => "  Hi Alice  ",
        "user_id" => first.user_id,
        "room_id" => Ecto.UUID.generate(),
        "id" => first.id
      }
    })

    messages = Chat.list_messages(room)
    reply = Enum.find(messages, &(&1.body == "Hi Alice"))
    assert reply.user_id == get_session(bob_conn, :user_id)
    assert reply.room_id == room.id
    assert reply.id != first.id
    expected = Enum.sort([first.id, reply.id])
    assert message_ids(alice) == expected
    assert message_ids(bob) == expected
    assert has_element?(alice, "#messages-#{reply.id}", "Bob")
    assert has_element?(alice, "#message-announcement", "1 new message. Total messages: 2.")
  end

  test "all history converges after late IDs and repeated events without leaking other rooms", %{
    room: room
  } do
    conn = post(build_conn(), ~p"/join", user: %{name: "Reader"})
    user = Chat.get_user(get_session(conn, :user_id))

    history =
      for number <- 1..60 do
        Repo.insert!(%Message{room_id: room.id, user_id: user.id, body: "History #{number}"})
      end

    expected = history |> Enum.map(& &1.id) |> Enum.sort()
    {:ok, first, _} = live(recycle(conn), ~p"/")
    {:ok, second, _} = live(recycle(conn), ~p"/")
    assert message_ids(first) == expected
    assert message_ids(second) == expected
    assert announcement_text(first) == ""

    late =
      Repo.insert!(%Message{
        id: "00000000-0000-7000-8000-000000000001",
        room_id: room.id,
        user_id: user.id,
        body: "Late commit with an earlier ID"
      })
      |> Repo.preload(:user)

    broadcast(room, late)
    expected = [late.id | expected]
    assert message_ids(first) == expected
    assert message_ids(second) == expected
    assert has_element?(first, "#message-announcement", "1 new message. Total messages: 61.")
    broadcast(room, late)
    assert message_ids(first) == expected
    assert message_ids(second) == expected
    assert has_element?(first, "#message-announcement", "1 new message. Total messages: 61.")

    other_room = Repo.insert!(Room.changeset(%Room{}, %{name: "Other", slug: "other"}))
    {:ok, elsewhere} = Chat.create_message(other_room, user, %{body: "Private to another room"})
    # Even a message incorrectly published on this room's topic must be ignored.
    broadcast(room, elsewhere)
    assert message_ids(first) == expected
    assert message_ids(second) == expected

    {:ok, newest} = Chat.create_message(room, user, %{body: "After the reset"})
    expected = Enum.sort([newest.id | expected])
    assert message_ids(first) == expected
    assert message_ids(second) == expected

    {:ok, fresh, _} = live(recycle(conn), ~p"/")
    assert message_ids(fresh) == expected
    assert announcement_text(fresh) == ""
  end

  test "remount restores the session and messages committed while the view was gone", %{
    room: room
  } do
    conn = post(build_conn(), ~p"/join", user: %{name: "Returning reader"})
    user = Chat.get_user(get_session(conn, :user_id))
    {:ok, before_disconnect} = Chat.create_message(room, user, %{body: "Already seen"})
    {:ok, original, _} = live(recycle(conn), ~p"/")
    assert message_ids(original) == [before_disconnect.id]
    GenServer.stop(original.pid, :normal)

    missed =
      Repo.insert!(%Message{
        id: "00000000-0000-7000-8000-000000000002",
        room_id: room.id,
        user_id: user.id,
        body: "Earlier ID committed while disconnected"
      })

    {:ok, also_missed} = Chat.create_message(room, user, %{body: "Another missed notification"})
    {:ok, restored, _} = live(recycle(conn), ~p"/")
    expected = Enum.sort([missed.id, before_disconnect.id, also_missed.id])
    assert has_element?(restored, "#current-user", user.name)
    assert message_ids(restored) == expected

    {:ok, after_reconnect} = Chat.create_message(room, user, %{body: "Live again"})
    assert message_ids(restored) == Enum.sort([after_reconnect.id | expected])
  end

  defp broadcast(room, message) do
    Phoenix.PubSub.broadcast(
      App.PubSub,
      Chat.messages_topic(room.slug),
      {:message_created, message}
    )
  end

  defp message_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#messages [data-message-id]")
    |> LazyHTML.attribute("data-message-id")
  end

  defp announcement_text(view) do
    view
    |> element("#message-announcement")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
