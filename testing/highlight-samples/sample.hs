-- This is a comment
module Sample where

greeting :: String
greeting = "hello world"

age :: Int
age = 42

greet :: String -> String
greet name = "Hi, " ++ name ++ "!"

{- Block comment -}
pi_val :: Float
pi_val = 3.14
