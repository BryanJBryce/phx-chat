defmodule App.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :normalized_name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:normalized_name])

    create table(:rooms, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:rooms, [:slug])

    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid), null: false
      add :room_id, references(:rooms, type: :uuid), null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:messages, [:room_id, :id])
  end
end
