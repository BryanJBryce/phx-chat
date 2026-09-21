defmodule AppWeb.ConnCase do
  @moduledoc """
  HTTP and LiveView tests share SQL Sandbox ownership with their request processes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AppWeb.Endpoint

      use AppWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AppWeb.ConnCase
    end
  end

  setup tags do
    App.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
