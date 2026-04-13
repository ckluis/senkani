// This is a comment
import Foundation

struct User {
    let name: String = "hello world"
    let age: Int = 42
    let active: Bool = true

    func greet() -> String {
        return "Hi, \(name)!"
    }
}
