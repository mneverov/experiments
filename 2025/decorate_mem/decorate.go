package main

import (
	"fmt"
	"log"
	"os"
)

/*
#include <stdlib.h>

void f(void)
{
  (void)malloc(1024*1024*1024);
}
*/
import "C"

func main() {
	C.f()

	data, err := os.ReadFile("/proc/self/maps")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(string(data))
}
