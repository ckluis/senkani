// This is a comment
import kotlin.math.PI

class User(val name: String, val age: Int = 42) {
    val active: Boolean = true

    fun greet(): String {
        return "Hi, $name!"
    }

    /* Block comment */
}

val count = 3.14
val nothing = null
