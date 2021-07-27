# Recreate zImage

Initially it was meant to be a small tool which is able to recreate `zImage` files from unpacked & stripped `vmlinux` 
images. However, life verified my plans.

This is how monstrosity was born :D 

## How to use it?
1. Install a standard toolset for compiling the Linux kernel.   
   *Usually `build-essential` suffices on Debian.*
2. Get a close-ish Linux sources for the kernel you're planning to recompress  
   For example any Linux v4 will should work with Linux v4.1 or v4.4. YMMV, the closer, the better.
3. Run `./rebuild_kernel.sh KERNEL_SRC_ROOT INPUT OUTPUT`


## Known problems
This is pretty much a proof-of-concept which is working reasonably well.

- Handling of non-absolute paths (e.g. `./linux-v3.1`) isn't complete everywhere, so use e.g. `$PWD/linux-v3.1`
- It was tested on Linux v3 and v4 and between these two there are some quirks. It may work on v5 but I didn't test it
- Rebuilt images are always LZMA-compressed. The code is prepared to handle any compression but there's no option now to
  set it. PRs are welcomed ;)
- There are no docs how it works and why. I have a ton of brain-dump notes but nothing organized yet.
