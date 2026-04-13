// This is a comment
package main

import "fmt"

type User struct {
	Name string
	Age  int
}

func greet(u User) string {
	return fmt.Sprintf("Hi, %s!", u.Name)
}

var count = 42
var pi = 3.14
var active = true
var nothing = nil
