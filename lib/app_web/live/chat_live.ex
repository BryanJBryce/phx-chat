defmodule AppWeb.ChatLive do
  use AppWeb, :live_view

  alias App.Chat
  alias AppWeb.Presence

  @impl true
  def mount(_params, session, socket) do
    slug = Chat.default_room_slug()
    if connected?(socket), do: Chat.subscribe(slug)

    room = Chat.get_default_room!()
    user = Chat.get_user(session["user_id"])

    if connected?(socket) && user do
      {:ok, _} = Presence.track(self(), Chat.presence_topic(slug), user.id, %{})
    end

    changeset = Chat.change_user(session["join_params"] || %{})

    changeset =
      if errors = session["join_errors"] do
        %{changeset | action: :insert, errors: errors, valid?: false}
      else
        changeset
      end

    {:ok,
     socket
     |> assign(:page_title, room.name)
     |> assign(:current_scope, nil)
     |> assign(:room, room)
     |> assign(:current_user, user)
     |> assign(:join_form, to_form(changeset))
     |> assign(:trigger_join, false)
     |> assign(:message_form, to_form(Chat.change_message()))
     |> assign(:last_message_id, nil)
     |> assign(:message_count, 0)
     |> assign(:message_announcement, nil)
     |> stream(:messages, [])
     |> refresh_roster()
     |> load_messages()}
  end

  @impl true
  def handle_event("validate_join", %{"user" => attrs}, socket) do
    changeset = %{Chat.change_user(attrs) | action: :validate}
    {:noreply, assign(socket, join_form: to_form(changeset), trigger_join: false)}
  end

  def handle_event("join", %{"user" => attrs}, socket) do
    changeset = %{Chat.change_user(attrs) | action: :insert}

    {:noreply, assign(socket, join_form: to_form(changeset), trigger_join: changeset.valid?)}
  end

  def handle_event("validate_message", %{"message" => attrs}, socket) do
    changeset = %{Chat.change_message(attrs) | action: :validate}
    {:noreply, assign(socket, :message_form, to_form(changeset))}
  end

  def handle_event("send_message", _params, %{assigns: %{current_user: nil}} = socket) do
    changeset =
      Chat.change_user(%{name: ""})
      |> Ecto.Changeset.add_error(:name, "Join before sending a message")
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, :join_form, to_form(changeset))}
  end

  def handle_event("send_message", %{"message" => attrs}, socket) do
    case Chat.create_message(socket.assigns.room, socket.assigns.current_user, attrs) do
      {:ok, _message} ->
        {:noreply, assign(socket, :message_form, to_form(Chat.change_message()))}

      {:error, changeset} ->
        {:noreply, assign(socket, :message_form, to_form(changeset))}
    end
  end

  def handle_event(event, _params, socket) when event in ["validate_join", "join"] do
    handle_event(event, %{"user" => %{}}, socket)
  end

  def handle_event(event, _params, socket) when event in ["validate_message", "send_message"] do
    handle_event(event, %{"message" => %{}}, socket)
  end

  @impl true
  def handle_info(:users_changed, socket), do: {:noreply, refresh_roster(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh_roster(socket)}
  end

  def handle_info({:message_created, _message}, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_info({:message_created, message}, socket) do
    previous_count = socket.assigns.message_count

    socket =
      if message.room_id == socket.assigns.room.id do
        receive_message(socket, message)
      else
        socket
      end

    {:noreply, announce_messages(socket, socket.assigns.message_count - previous_count)}
  end

  defp receive_message(socket, message) do
    if is_nil(socket.assigns.last_message_id) or message.id > socket.assigns.last_message_id do
      socket
      |> stream_insert(:messages, message)
      |> assign(:last_message_id, message.id)
      |> update(:message_count, &(&1 + 1))
    else
      load_messages(socket)
    end
  end

  defp announce_messages(socket, count) when count <= 0, do: socket

  defp announce_messages(socket, count) do
    text = if count == 1, do: "1 new message.", else: "#{count} new messages."
    # The total makes consecutive one-message updates distinct to assistive tech.
    assign(
      socket,
      :message_announcement,
      "#{text} Total messages: #{socket.assigns.message_count}."
    )
  end

  defp load_messages(%{assigns: %{current_user: nil}} = socket), do: socket

  defp load_messages(socket) do
    messages = Chat.list_messages(socket.assigns.room)
    last_message = List.last(messages)

    socket
    |> stream(:messages, messages, reset: true)
    |> assign(:last_message_id, last_message && last_message.id)
    |> assign(:message_count, length(messages))
  end

  defp refresh_roster(socket) do
    presences = Presence.list(Chat.presence_topic(socket.assigns.room.slug))

    users =
      Enum.map(Chat.list_users(), fn user ->
        online? = match?(%{metas: [_ | _]}, Map.get(presences, user.id))
        %{id: user.id, name: user.name, online?: online?}
      end)

    stream(socket, :users, users, reset: true)
  end
end
