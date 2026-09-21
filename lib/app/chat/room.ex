defmodule App.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "rooms" do
    field :name, :string
    field :slug, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
