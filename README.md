# Non-Blocking 2-Way L1 Data Cache

A SystemVerilog implementation of an 8 KiB, 2-way set-associative L1 data cache with write-back/write-allocate behavior, LRU replacement, two Miss Status Holding Registers (MSHRs), and hit-under-miss support.

The design demonstrates the core structures and control flow used in a non-blocking processor cache, including dirty evictions, cache-line refills, multiple outstanding misses, and request backpressure.

## Features

- 8 KiB cache capacity
- 2-way set associativity
- 64 sets
- 64-byte cache lines
- 32-bit CPU data interface
- Write-back caching
- Write-allocate on store misses
- Dirty-bit tracking
- Dirty victim writeback
- Byte write enables
- LRU replacement
- Two MSHRs
- Hit-under-miss
- Up to two outstanding lower-memory refills
- Tagged refill responses
- Same-set locking during an outstanding miss
- Hardware performance counters
- Self-checking SystemVerilog testbench

## Cache Organization

The default configuration uses:

- 32-bit addresses
- 64-byte cache lines
- 64 sets
- 2 ways
- 32-bit CPU words

The 32-bit address is divided into:

    31                  12 11           6 5             0
    +----------------------+---------------+---------------+
    |      TAG (20)        |  SET (6)      | OFFSET (6)    |
    +----------------------+---------------+---------------+

Each 64-byte cache line contains sixteen 32-bit words.

Total cache capacity:

    64 sets x 2 ways x 64 bytes = 8 KiB

## Architecture

Each cache set contains two ways.

Each way maintains:

- Tag
- Valid bit
- Dirty bit
- Cache-line data

A per-set LRU bit determines which way should be replaced when both ways are valid.

                         CPU
                          |
                    Load / Store
                          |
                          v
                 +----------------+
                 |   L1 D-Cache   |
                 |                |
                 |  Way 0  Way 1 |
                 |  Tag    Tag    |
                 |  Data   Data   |
                 +-------+--------+
                         |
                       Miss
                         |
                         v
                 +----------------+
                 |   MSHR Table   |
                 |                |
                 |   MSHR 0       |
                 |   MSHR 1       |
                 +-------+--------+
                         |
                         v
                   Lower Memory

## Cache Hit

For each CPU request, the set index selects both ways.

The requested tag is compared against both stored tags in parallel.

                CPU Address
                     |
              +------+------+
              |             |
           Way 0          Way 1
          Tag Compare    Tag Compare
              |             |
              +------+------+
                     |
                    Hit?
                     |
                     v
                 CPU Response

On a read hit, the selected word is returned to the CPU.

On a write hit, the selected bytes are updated and the cache line is marked dirty.

## Write-Back Policy

The cache uses write-back rather than immediately updating lower memory after every store.

On a store hit:

    CPU Store
        |
        v
    Update Cache Line
        |
        v
    Dirty = 1

The modified line is written to lower memory only if it is later selected for eviction.

## Write-Allocate Policy

A store that misses in the cache first fetches the corresponding cache line from lower memory.

    Store Miss
        |
        v
    Fetch Cache Line
        |
        v
    Install Cache Line
        |
        v
    Apply Store
        |
        v
    Mark Dirty

## Replacement Policy

The cache uses Least Recently Used replacement.

Because the cache is 2-way set associative, only one LRU bit is required per set.

When Way 0 is accessed, Way 1 becomes the next replacement candidate.

When Way 1 is accessed, Way 0 becomes the next replacement candidate.

Invalid ways are always selected before evicting a valid line.

## Dirty Eviction

When a miss requires replacement, the selected victim is checked for valid and dirty state.

For a clean victim:

    Miss
      |
      v
    Select Victim
      |
      v
    Refill New Line

For a dirty victim:

    Miss
      |
      v
    Select Victim
      |
      v
    Write Old Line to Memory
      |
      v
    Refill New Line

## Miss Status Holding Registers

The cache contains two Miss Status Holding Registers.

An MSHR stores the state required to track an outstanding cache miss, including:

- CPU request ID
- Requested tag
- Set index
- Word index
- Read/write operation
- Store data
- Byte strobes
- Selected victim way
- Victim metadata
- Current miss state

This allows a cache miss to remain outstanding without losing the original CPU request.

## Hit-Under-Miss

A conventional blocking cache stalls CPU requests while a miss waits for lower memory.

This design can continue processing cache hits to independent sets while another miss is outstanding.

Example:

    Request A -> MISS
                   |
                   | Waiting for memory
                   |
    Request B -> HIT
                   |
                   +--> Response B

    Later:

                   +--> Response A

The self-checking testbench verifies this behavior by confirming that a younger cache hit completes before an older outstanding miss.

## Multiple Outstanding Misses

Because the cache contains two MSHRs, two misses to different sets can be tracked simultaneously.

    MSHR 0 -> Miss A
    MSHR 1 -> Miss B

If both MSHRs are occupied and another miss arrives, the cache applies backpressure until an MSHR becomes available.

The current design permits only one outstanding miss per cache set. This prevents conflicting replacement decisions and simplifies same-set miss handling.

## CPU Interface

Requests use a ready/valid handshake.

Important request signals include:

- cpu_req_valid
- cpu_req_ready
- cpu_req_id
- cpu_req_addr
- cpu_req_write
- cpu_req_wdata
- cpu_req_wstrb

Response signals include:

- cpu_resp_valid
- cpu_resp_ready
- cpu_resp_id
- cpu_resp_rdata

Request IDs allow responses to be associated with their original CPU requests.

## Lower-Memory Interface

The lower-memory interface operates on complete 64-byte cache lines.

Memory request signals include:

- mem_req_valid
- mem_req_ready
- mem_req_write
- mem_req_addr
- mem_req_wdata
- mem_req_mshr_id

Refill response signals include:

- mem_resp_valid
- mem_resp_ready
- mem_resp_mshr_id
- mem_resp_rdata

The MSHR ID identifies which outstanding miss a refill belongs to.

## Verification

The project includes a self-checking SystemVerilog testbench.

Directed tests cover:

1. Cold load miss and refill
2. Subsequent cache hit
3. Write hit
4. Byte write enables
5. LRU replacement
6. Dirty victim writeback
7. Write-allocate behavior
8. Hit-under-miss
9. Two simultaneous outstanding misses
10. Backpressure when both MSHRs are occupied

The testbench also tracks:

- Total cache accesses
- Cache hits
- Cache misses
- Dirty writebacks
- MSHR stall cycles
- Same-set conflict stalls

All directed tests pass.

## Current Limitations

- One outstanding miss per cache set
- No same-line miss merging
- No cache coherence protocol
- No atomic memory operations
- No ECC
- 32-bit aligned CPU accesses
- Single CPU request stream
- Abstract lower-memory interface rather than AXI
- No prefetcher

## Possible Extensions

- Same-line MSHR merging
- 4-way set associativity
- Tree-PLRU replacement
- Stride prefetching
- Victim cache
- AXI lower-memory interface
- Integration with a RISC-V processor
- Support for additional load/store sizes
