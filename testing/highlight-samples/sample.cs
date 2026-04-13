// This is a comment
using System;

namespace App {
    public class User {
        public string Name { get; set; } = "hello world";
        public int Age { get; set; } = 42;
        public bool Active = true;

        public string Greet() {
            return $"Hi, {Name}!";
        }

        /* Block comment */
        char initial = 'A';
    }
}
