defmodule App.Chat do
  @moduledoc """
  Persistence and notifications for chat. Mutation functions are standalone
  write boundaries: call them outside enclosing Repo transactions so broadcasts
  follow committed writes.
  """
  import Ecto.Query

  alias App.Chat.{Message, Room, User}
  alias App.Repo

  def default_room_slug, do: "general"
  def users_topic, do: "chat:users"
  def messages_topic(slug), do: "chat:rooms:#{slug}:messages"
  def presence_topic(slug), do: "chat:rooms:#{slug}:presence"

  def subscribe(slug) do
    :ok = Phoenix.PubSub.subscribe(App.PubSub, users_topic())
    :ok = Phoenix.PubSub.subscribe(App.PubSub, messages_topic(slug))
    Phoenix.PubSub.subscribe(App.PubSub, presence_topic(slug))
  end

  def get_default_room!, do: Repo.get_by!(Room, slug: default_room_slug())

  def ensure_default_room! do
    %Room{}
    |> Room.changeset(%{name: "General", slug: default_room_slug()})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :slug)

    get_default_room!()
  end

  def change_user(attrs \\ %{}), do: User.changeset(%User{}, attrs)

  def get_or_create_user(attrs) do
    changeset = change_user(attrs)

    with {:ok, candidate} <- Ecto.Changeset.apply_action(changeset, :insert) do
      case Repo.get_by(User, normalized_name: candidate.normalized_name) do
        nil ->
          with {:ok, user} <- Repo.insert(changeset) do
            :ok = Phoenix.PubSub.broadcast(App.PubSub, users_topic(), :users_changed)
            {:ok, user}
          end

        user ->
          {:ok, user}
      end
    end
  end

  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  def list_users, do: Repo.all(from u in User, order_by: [u.normalized_name, u.id])

  def list_messages(%Room{id: room_id}) do
    Repo.all(from m in Message, where: m.room_id == ^room_id, order_by: m.id, preload: :user)
  end

  def change_message(attrs \\ %{}), do: Message.changeset(%Message{}, attrs)

  def create_message(%Room{} = room, %User{} = user, attrs) do
    %Message{room_id: room.id, user_id: user.id}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        message = Repo.preload(message, :user)

        :ok =
          Phoenix.PubSub.broadcast(
            App.PubSub,
            messages_topic(room.slug),
            {:message_created, message}
          )

        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
