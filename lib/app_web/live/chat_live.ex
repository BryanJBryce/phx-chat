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
     |> refresh_roster()}
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

  @impl true
  def handle_info(:users_changed, socket), do: {:noreply, refresh_roster(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh_roster(socket)}
  end

  def handle_info({:message_created, _message}, socket), do: {:noreply, socket}

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
