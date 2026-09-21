defmodule App.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias App.Chat.Input

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
  @foreign_key_type :binary_id

  schema "messages" do
    field :body, :string
    belongs_to :user, App.Chat.User
    belongs_to :room, App.Chat.Room
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> Input.cast_text(attrs, :body)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:room_id)
  end
end
