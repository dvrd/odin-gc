package gc

import "core:c"
import "core:fmt"
import "core:mem"
import "core:sys/darwin"

foreign import libc "System.framework"
foreign libc {
	@(link_name = "mmap")
	mmap :: proc(addr: rawptr, len: c.size_t, prot: c.int, flags: c.int, fd: c.int, offset: int) -> rawptr ---
	@(link_name = "mprotect")
	mprotect :: proc(addr: rawptr, len: c.size_t, prot: c.int) -> c.int ---
	@(link_name = "munmap")
	munmap :: proc(addr: rawptr, len: c.size_t) -> c.int ---
}

MAP_FAILED :: rawptr(~uintptr(0))

word :: [^]byte

Block :: struct {
	size: uint,
	used: bool,
	next: ^Block,
	data: word,
}

heap_start: ^Block
top: ^Block = heap_start

Search_Mode :: enum {
	First_Fit,
	Next_Fit,
	Best_Fit,
}

search_start: ^Block = heap_start
search_mode := Search_Mode.First_Fit

align :: proc(n: uint) -> uint {
	return (n + size_of(word) - 1) & ~uint(size_of(word) - 1)
}

alloc_size :: proc(size: uint) -> uint {
	return size + size_of(Block) - size_of(word)
}

reserve_and_commit :: proc(size: uint) -> (b: [^]byte, err: mem.Allocator_Error) {
	raw := mmap(
		nil,
		alloc_size(size),
		darwin.PROT_NONE,
		darwin.MAP_PRIVATE | darwin.MAP_ANONYMOUS,
		-1,
		0,
	)
	if raw == MAP_FAILED {
		return nil, .Out_Of_Memory
	}

	fail := mprotect(raw, uint(size), darwin.PROT_READ | darwin.PROT_WRITE)
	if fail != 0 {
		return nil, .Out_Of_Memory
	}

	return ([^]byte)(uintptr(raw)), err
}

reset_heap :: proc() {
	// Already reset.
	if (heap_start == nil) {
		return
	}

	// Roll back to the beginning.
	heap_start = nil
	top = nil
	search_start = nil
}

init_heap :: proc(mode: Search_Mode) {
	search_mode = mode
	reset_heap()
}

split :: proc(block: ^Block, size: uint) -> ^Block {
	new_base := mem.ptr_offset(block.data, block.size - size)
	new_block := get_header(new_base)
	new_block.size = size
	new_block.used = true
	new_block.next = block.next
	new_block.data = new_base
	block.next = new_block
	block.size -= size

	return new_block
}

can_split :: proc(block: ^Block, size: uint) -> (ok: bool) {
	return block.size % size == 0
}

list_allocate :: proc(block: ^Block, size: uint) -> (new_block: ^Block) {
	new_block = block

	fmt.println("LIST ALLOCATE")
	if (can_split(block, size)) {
		new_block = split(block, size)
	}

	new_block.used = true
	new_block.size = size

	fmt.println("ALLOCATING BLOCK")
	return
}

first_fit :: proc(size: uint) -> ^Block {
	block := heap_start

	for block != nil {
		// O(n) search.
		if block.used || block.size < size {
			block = block.next
			continue
		}

		return block // Found the block
	}

	return nil
}

next_fit :: proc(size: uint) -> ^Block {
	if search_start == nil {
		search_start = heap_start
	}

	block := search_start

	for block != nil {
		// O(n) search.
		if block.used || block.size < size {
			block = block.next
			search_start = block
			continue
		}

		return block // Found the block
	}

	return nil
}

best_fit :: proc(size: uint) -> ^Block {
	if search_start == nil {
		search_start = heap_start
	}

	fmt.println("SEARCHING")
	best_fit : ^Block
	block := search_start
	for block != nil {
		fmt.println("CHECKING", block)
		if block.used || block.size < 0 {
			block = block.next 
			continue
		}

		if block.size == size {
			search_start = block
			return block
		}
		fmt.println("NOT PERFECT MATCH")

		best_fit = block.size > best_fit.size ? best_fit : block
		block = block.next 

		fmt.println("NEW BEST FIT")
		if search_start == block {
			fmt.println("SPLITING BEST_FIT", best_fit)
			return list_allocate(best_fit, size)
		}
	}
	fmt.println("NO BLOCK FOUND")

	return nil
}

find_block :: proc(size: uint) -> (b: ^Block) {
	switch search_mode {
	case .First_Fit:
		b = first_fit(size)
	case .Next_Fit:
		b = next_fit(size)
	case .Best_Fit:
		b = best_fit(size)
	}
	return
}

alloc :: proc(size: uint) -> (data: word, err: mem.Allocator_Error) {
	total_size := align(size)

	block := find_block(total_size);if block != nil {
		return block.data, nil
	}
	fmt.println("REQUESTING NEW BLOCK")

	chunk := reserve_and_commit(total_size) or_return
	base := mem.ptr_offset(chunk, size_of(Block) - size_of(word))

	block = cast(^Block)(chunk)
	block.size = size
	block.used = true
	block.data = base

	// Init heap.
	if (heap_start == nil) {
		heap_start = block
	}

	// Chain the blocks.
	if (top != nil) {
		top.next = block
	}

	top = block

	fmt.println("NEW BLOCK ASSIGNED")
	return block.data, nil
}

get_header :: proc(data: word) -> ^Block {
	return cast(^Block)mem.ptr_offset(data, size_of(word) - size_of(Block))
}

free :: proc(data: word) {
	fmt.println("FREE BLOCK")
	block := get_header(data)
	block.used = false
}

main :: proc() {
	fmt.println("Initiating heap")
	init_heap(.Best_Fit)
	alloc(8)
	block1, _ := alloc(64)
	alloc(8)
	block2, _ := alloc(16)

	fmt.println("FIRST-1", get_header(block1))
	fmt.println("SECOND-1", get_header(block2))
	assert(get_header(block1).size == 64, "Block should be same size as requested")
	assert(get_header(block2).size == 16, "Block should be same size as requested")

	free(block2)
	free(block1)

	block3, _ := alloc(16)
	fmt.println("FIRST-2", get_header(block1))
	fmt.println("SECOND-2", get_header(block2))
	fmt.println("THIRD", get_header(block3))
	assert(get_header(block3) == get_header(block2), "Both blocks should point to the same place")

	block3, _ = alloc(16)
	assert(get_header(block3) == get_header(block1), "Both blocks should point to the same place")
}
