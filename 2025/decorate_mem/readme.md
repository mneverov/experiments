See issues [#71546](https://github.com/golang/go/issues/71546) and [#75324](https://github.com/golang/go/issues/75324).

# TL;DR;

Memory mappings in linux for a process can be found in `/proc/{pid}/maps` or from inside the process `/proc/self/maps`. 
