defmodule AppWeb.JoinController do
  use AppWeb, :controller

  alias App.Chat

  def create(conn, params) do
    user_params = Map.get(params, "user", %{})

    case Chat.get_or_create_user(user_params) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> redirect(to: ~p"/")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> Phoenix.LiveView.Controller.live_render(AppWeb.ChatLive,
          session: %{"join_params" => user_params, "join_errors" => changeset.errors}
        )
    end
  end
end
