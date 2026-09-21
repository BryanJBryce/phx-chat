defmodule App.Chat.Input do
  @moduledoc false
  import Ecto.Changeset

  # Both chat forms accept one text field. Keep unsupported values out of form
  # params as well as database writes: Ecto retains failed casts in form values.
  def cast_text(data, attrs, field) do
    value =
      case attrs do
        %{} -> Map.get(attrs, Atom.to_string(field), Map.get(attrs, field))
        _ -> :invalid
      end

    if is_nil(value) or (is_binary(value) and String.valid?(value)) do
      data
      |> cast(%{field => value}, [field])
      |> update_change(field, &String.trim/1)
      |> validate_required([field])
      |> validate_format(field, ~r/\A[^\x00]*\z/u, message: "cannot contain NUL characters")
    else
      data
      |> cast(%{field => nil}, [field])
      |> add_error(field, "must be text")
    end
  end
end
