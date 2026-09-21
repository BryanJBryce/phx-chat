defmodule AppWeb.Presence do
  @moduledoc "Tracks joined LiveView connections so multiple tabs share one online identity."
  use Phoenix.Presence, otp_app: :app, pubsub_server: App.PubSub
end
