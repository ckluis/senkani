# This is a comment
import os

class User:
    name: str = "hello world"
    age: int = 42
    active: bool = True

    def greet(self) -> str:
        return f"Hi, {self.name}!"

count = 3.14
result = None
