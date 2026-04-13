// TSX with JSX
import React from 'react'

interface Props {
    name: string
    count: number
}

const App = ({ name, count }: Props) => {
    const active = true
    return <div className="app">{name}: {count}</div>
}

// Number and null
const x = 42
const y = null
