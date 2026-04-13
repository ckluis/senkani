// This is a comment
use std::fmt;

struct User {
    name: String,
    age: i32,
}

fn greet(user: &User) -> String {
    format!("Hi, {}!", user.name)
}

let count: i32 = 42;
let pi: f64 = 3.14;
let active: bool = true;
let ch: char = 'a';

/* Block comment */
