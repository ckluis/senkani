// This is a comment
import { User } from './models'

interface Config {
    name: string
    count: number
    active: boolean
}

const greeting: string = "hello world"
const age: number = 42
const enabled = true
const nothing = null

/* Block comment */
function greet(user: User): string {
    return `Hi, ${user.name}!`
}
