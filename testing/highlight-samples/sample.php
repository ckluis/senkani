<?php
// This is a comment
namespace App\Models;

class User {
    public string $name = "hello world";
    public int $age = 42;
    public bool $active = true;

    public function greet(): string {
        return "Hi, {$this->name}!";
    }

    /* Block comment */
}

$count = 3.14;
$nothing = null;
