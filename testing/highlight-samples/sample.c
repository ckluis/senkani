// This is a comment
#include <stdio.h>
#include "myheader.h"

struct User {
    char *name;
    int age;
};

int greet(struct User *u) {
    printf("Hi, %s!\n", u->name);
    return 0;
}

/* Block comment */
int count = 42;
char ch = 'A';
