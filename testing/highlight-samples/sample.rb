# This is a comment
require 'json'

class User
  attr_reader :name, :age

  def initialize(name, age)
    @name = name
    @age = 42
  end

  def greet
    "Hi, #{@name}!"
  end
end

active = true
nothing = nil
pi = 3.14
