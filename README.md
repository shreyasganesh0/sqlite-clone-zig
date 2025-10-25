# SQLite Clone in Zig

This is a clone of the SQLite database built from scratch in Zig. This project was undertaken as a personal deep dive to understand how modern databases work at the lowest level, from file format and page parsing to B-Tree data structures.

This implementation is not a complete SQL database but successfully parses a real `.db` file, reads the schema, and traverses the B-Tree to extract metadata.

## Why This Project?

The goal was not to build a production-ready database, but to answer these questions by writing code:
* How is data *really* stored on disk by a database?
* How does the B-Tree, a data structure I've only seen in textbooks, work in practice?
* How does SQLite manage variable-length data and schema in a single file?
* How can a low-level language like Zig be used for performance-critical parsing and file I/O?

## Features Implemented
* **Database File Header Parsing:** Reads the 100-byte header to validate the file and extract the page size.
* **B-Tree Traversal:** Implements a stack-based (DFS) traversal of the B-Tree to visit all nodes.
* **Page Parsing:** Differentiates between B-Tree interior pages (`0x05`) and leaf pages (`0x0D`).
* **Schema Reading:** Successfully walks the `sqlite_schema` table (always on page 1) to count the number of tables in the database.
* **Varint Parsing:** Implements a `varint` parser to correctly read variable-length integers (like keys) from the page data.

## Technical Deep Dive: Walking the B-Tree

The most challenging part was parsing the B-Tree. The `btree_walk` function recursively explores the database's internal tree structure. It starts at the root page (page 1) and uses a stack to perform a depth-first search.

For each page, it:
1.  Parses the page header to find the page type (Interior vs. Leaf) and number of cells.
2.  If it's an **Interior Page** (`0x05`), it reads each cell, parses the `varint` key, and finds the child page number to add to the stack.
3.  If it's a **Leaf Page** (`0x0D`), it counts the cells, which represent the actual data (in this case, table definitions).

This snippet shows the core logic for reading a child page pointer from an interior node cell:

```zig
// (Inside btree_walk function)
// For each cell in an Interior Page...
for (cell_pointer_array) |value| {
    const file_offset: u16 = value;

    // ...Find the 4-byte page number at the start of the cell
    const number_arr: *const [4]u8 = @ptrCast(&page.data[(file_offset - header_size) .. (file_offset - header_size) + 4]);
    const page_number = std.mem.readInt(u32, number_arr, .big);

    // ... (Varint key parsing omitted for brevity) ...

    // Now, seek to that child page and add it to the stack
    var page_buf_under: [4096]u8 = undefined;
    _ = try file.seekTo((page_number - 1) * 4096); // Seek to the start of the new page
    _ = try file.read(&page_buf_under);

    var page_under: btree_page_table_t = undefined;
    page_under.page_header.parse(&page_buf_under);
    page_under.data = page_buf_under[header_size_under..];

    try stack.append(page_under); // Add new page to the DFS stack
}
```
## How to Run
1. Ensure you have zig (0.13+) installed.
2. Clone the repository: ```git clone https://github.com/shreyasganesh0/sqlite-clone-zig.git```
3. Build the project: ```zig build```
4. Run the .dbinfo command on a sample database:
```
 ./zig-out/bin/main sample.db .dbinfo
```
Output:
```
database page size: 4096
number of tables: 2
```
