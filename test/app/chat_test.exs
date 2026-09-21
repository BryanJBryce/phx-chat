defmodule App.ChatTest do
  use App.DataCase

  alias App.Chat
  alias App.Chat.{Message, Room, User}

  test "names select one persisted identity and blank names never publish a user" do
    :ok = Phoenix.PubSub.subscribe(App.PubSub, Chat.users_topic())
    assert {:ok, user} = Chat.get_or_create_user(%{name: "  Alice  "})
    assert_receive :users_changed
    assert {:ok, reused} = Chat.get_or_create_user(%{name: "aLiCe"})
    assert reused.id == user.id
    assert reused.name == "Alice"
    assert [%User{id: id}] = Chat.list_users()
    assert id == user.id

    assert {:error, changeset} = Chat.get_or_create_user(%{name: " \n\t "})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
    refute_received :users_changed
  end

  test "UUIDv7 messages retain their sender, stay in their room, and sort by ID" do
    room = Chat.ensure_default_room!()
    assert Chat.ensure_default_room!().id == room.id
    other_room = Repo.insert!(Room.changeset(%Room{}, %{name: "Other", slug: "other"}))
    {:ok, user} = Chat.get_or_create_user(%{name: "Alice"})
    {:ok, other_user} = Chat.get_or_create_user(%{name: "Bob"})
    :ok = Phoenix.PubSub.subscribe(App.PubSub, Chat.messages_topic(room.slug))

    assert {:ok, message} =
             Chat.create_message(room, user, %{
               body: "  First line\nSecond line  ",
               user_id: other_user.id,
               room_id: other_room.id
             })

    assert_receive {:message_created, %{id: message_id, user: %{name: "Alice"}}}
    assert message_id == message.id
    assert message.user_id == user.id
    assert message.room_id == room.id
    assert message.body == "First line\nSecond line"
    assert %DateTime{time_zone: "Etc/UTC"} = message.inserted_at

    for entity <- [user, room, message] do
      assert <<_::binary-size(14), "7", _::binary>> = entity.id
    end

    earlier =
      Repo.insert!(%Message{
        id: "00000000-0000-7000-8000-000000000001",
        body: "Committed later, ordered earlier",
        user_id: user.id,
        room_id: room.id
      })

    {:ok, elsewhere} = Chat.create_message(other_room, user, %{body: "Different room"})
    assert Enum.map(Chat.list_messages(room), & &1.id) == [earlier.id, message.id]
    assert Enum.map(Chat.list_messages(other_room), & &1.id) == [elsewhere.id]

    assert {:error, changeset} = Chat.create_message(room, user, %{body: " \n\t "})
    assert %{body: ["can't be blank"]} = errors_on(changeset)
    assert [_, _] = Chat.list_messages(room)
    refute_received {:message_created, _}
  end
end
