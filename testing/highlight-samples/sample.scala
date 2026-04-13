// This is a comment
import scala.collection.mutable

class User(val name: String, val age: Int = 42) {
  val active: Boolean = true

  def greet(): String = {
    s"Hi, $name!"
  }

  /* Block comment */
}

val count = 3.14
val nothing = null
