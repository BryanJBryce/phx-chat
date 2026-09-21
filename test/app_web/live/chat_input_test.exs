defmodule AppWeb.ChatInputTest do
  use AppWeb.ConnCase
  import Phoenix.LiveViewTest

  alias App.Chat

  setup do
    %{room: Chat.ensure_default_room!()}
  end

  test "unsafe joins return accessible validation instead of a database or render crash" do
    Phoenix.PubSub.subscribe(App.PubSub, Chat.users_topic())
    oversized = Base.encode64(:crypto.strong_rand_bytes(3200))
    combining = "a" <> String.duplicate("\u0301", 100)

    # Each input reaches a different failure boundary: form shape, field shape,
    # UTF-8/SQL text encoding, index capacity, and grapheme-vs-codepoint length.
    for {params, error} <- [
          {%{"user" => "Alice"}, "must be text"},
          {%{"user" => %{"name" => %{"nested" => "Alice"}}}, "must be text"},
          {%{"user" => %{"name" => <<255>>}}, "must be text"},
          {%{"user" => %{"name" => "A\0B"}}, "cannot contain NUL characters"},
          {%{"user" => %{"name" => oversized}}, "must be at most 100 characters"},
          {%{"user" => %{"name" => combining}}, "must be at most 100 characters"}
        ] do
      conn = post(build_conn(), ~p"/join", params)
      document = conn |> html_response(422) |> LazyHTML.from_document()

      assert [_] =
               document
               |> LazyHTML.query(
                 "#user_name[aria-invalid=true][aria-describedby=user_name-errors]"
               )
               |> LazyHTML.attribute("id")

      assert document |> LazyHTML.query("#user_name-errors") |> LazyHTML.text() =~ error
      refute get_session(conn, :user_id)
    end

    assert Chat.list_users() == []
    refute_received :users_changed

    # A valid multibyte name at the codepoint limit still persists and can rejoin.
    name = String.duplicate("É", 100)
    joined = post(build_conn(), ~p"/join", user: %{name: name})
    assert redirected_to(joined) == ~p"/"
    reused = post(build_conn(), ~p"/join", user: %{name: String.downcase(name)})
    assert get_session(reused, :user_id) == get_session(joined, :user_id)
  end

  test "malformed live events and NUL messages leave the forms usable without publishing", %{
    conn: conn,
    room: room
  } do
    Phoenix.PubSub.subscribe(App.PubSub, Chat.messages_topic(room.slug))
    {:ok, visitor, _} = live(conn, ~p"/")

    # Raw events deliberately bypass the browser's text-only form controls.
    render_change(visitor, "validate_join", %{"user" => "Alice"})
    assert has_element?(visitor, "#user_name-errors", "must be text")
    render_submit(visitor, "join", %{})
    assert has_element?(visitor, "#user_name-errors", "can't be blank")

    join_form = form(visitor, "#join-form", user: %{name: "Alice"})
    render_submit(join_form)
    joined_conn = follow_trigger_action(join_form, conn)
    {:ok, joined, _} = live(recycle(joined_conn), ~p"/")

    render_change(joined, "validate_message", %{"message" => %{"body" => ["bad"]}})
    assert has_element?(joined, "#message_body-errors", "must be text")
    render_submit(joined, "send_message", %{})
    assert has_element?(joined, "#message_body-errors", "can't be blank")
    render_submit(joined, "send_message", %{"message" => %{"body" => "a\0b"}})
    assert has_element?(joined, "#message_body-errors", "cannot contain NUL characters")

    assert has_element?(
             joined,
             "#message_body[aria-invalid=true][aria-describedby=message_body-errors]"
           )

    assert Chat.list_messages(room) == []
    refute_received {:message_created, _}

    joined
    |> form("#message-form", message: %{body: "Recovered\nwith a new line"})
    |> render_change()

    refute has_element?(joined, "#message_body[aria-invalid=true]")
    refute has_element?(joined, "#message_body[aria-describedby]")
    refute has_element?(joined, "#message_body-errors")

    joined
    |> form("#message-form", message: %{body: "Recovered\nwith a new line"})
    |> render_submit()

    assert_receive {:message_created, message}
    assert has_element?(joined, "#messages-#{message.id}", "Recovered")
    assert [persisted] = Chat.list_messages(room)
    assert persisted.id == message.id
  end
end
