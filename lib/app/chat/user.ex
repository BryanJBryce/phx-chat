defmodule App.Chat.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "users" do
    field :name, :string
    field :normalized_name, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    changeset =
      user
      |> cast(attrs, [:name])
      |> update_change(:name, &String.trim/1)
      |> validate_required([:name])

    name = get_field(changeset, :name) || ""

    changeset
    |> put_change(:normalized_name, String.downcase(name))
    |> unique_constraint(:normalized_name,
      error_key: :name,
      message: "is already in use; try joining again"
    )
  end
end
