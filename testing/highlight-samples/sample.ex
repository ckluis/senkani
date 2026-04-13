# This is a comment
defmodule User do
  @name "hello world"
  @age 42

  def greet(name) do
    "Hi, #{name}!"
  end

  defp helper(x) do
    x * 3.14
  end
end

active = true
nothing = nil
atom_val = :hello
