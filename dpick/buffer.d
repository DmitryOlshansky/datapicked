module dpick.buffer;

import std.algorithm, std.range;

enum isBuffer(T) = __traits(compiles, (ref T buf){
    if(!buf.empty) {
        auto v = buf.front;
        static assert(is(typeof(v) : ubyte));        
        assert(buf[0] == v);
        assert(buf.has(2));
        auto m = buf.mark();
        buf.popFront();        
        auto s = buf.slice(m);
        static assert(isRandomAccessRange!(typeof(s)));
        static assert(is(ElementType!(typeof(s)) : ubyte));
        buf.restore(m);
    }
});

//can slice buffer's data directly, not copies nessary
enum isZeroCopy(Buffer)  = isBuffer!Buffer && __traits(compiles, (Buffer buf){ 
    auto m = buf.mark();
    //slice may as well take only L-values
    alias SliceType = typeof(buf.slice(m));
    static assert(is(SliceType : immutable(ubyte)[]));
});

/// Conceptual mark-slice Buffer with lookahead
struct BufferConcept {
    struct Range { }
    struct Mark { }
    ///InputRange troika
    @property ubyte front(){ assert(0); }
    ///ditto
    @property bool empty(){ assert(0); }
    ///ditto
    void popFront(){ assert(0); }
    /// lookahead from current position (extends buffer as required)
    ubyte opIndex(size_t idx){ assert(0); }
    /// check if the buffer has at least bytes left in it (so can use lookahead)
    @property bool has(size_t n){ assert(0); }
    /// instructs the underlying abstraction
    /// to keep a hidden 'absolute offset' to slice off later
    Mark mark(){ return Mark.init; }
    /// Reset buffer state to previously marked position
    void restore(ref Mark ){ assert(0); }
    /// Peek at slice from $(D m) to the current position
    Range slice(ref Mark m){ assert(0); }
}

struct ArrayBuffer(T) {
    static struct Mark { size_t ofs; }
    @property ubyte front()
    in {  assert(!empty); }
    body { return data[cur]; }
    @property bool empty(){ return cur == data.length; }    
    void popFront()
    in {  assert(!empty); }
    body { cur++; }
    ubyte opIndex(size_t idx){ return data[cur+idx]; }
    @property bool has(size_t n){ return data.length  >= cur + n; }
    void restore(Mark m){ cur = m.ofs; }
    Mark mark(){ return Mark(cur); }
    T[] slice(Mark m){ return data[m.ofs..cur]; } 
private:
    T[] data;
    size_t cur;
}

auto buffer()(ubyte[] data)
{
    return ArrayBuffer!ubyte(data);
}

auto buffer(T)(T[] data)
    if(is(T : ubyte))
{
    return ArrayBuffer!T(data);
}

static assert(isBuffer!(ArrayBuffer!ubyte));
static assert(isBuffer!(ArrayBuffer!(const(ubyte))));
static assert(isZeroCopy!(ArrayBuffer!(immutable(ubyte))));

unittest
{
    auto buf = buffer([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    assert(buf.has(9));
    assert(buf[0] == 1);
    assert(buf.front == 1);
    buf.popFront();
    assert(buf.front == 2);
    assert(buf[0] == 2 && buf[1] == 3);
    auto m = buf.mark();
    assert(buf.has(8));
    foreach(_; 0..8)
        buf.popFront();
    assert(buf.empty);
    auto s = buf.slice(m);
    assert(s == [2, 3, 4, 5, 6, 7, 8, 9]);
    buf.restore(m);
    assert(buf.front == 2 && buf[1] == 3);
}

struct GenericBuffer {
    static struct Mark {
        @disable this(this);
        ~this() {
            if(buf)
                buf.discard(pos);
        }
        ulong pos;
        GenericBuffer* buf;
    }

    this(size_t delegate(ubyte[]) readBlock, size_t chunk, size_t initial) {
        assert((chunk & (chunk-1)) == 0);
        chunkSize = chunk;
        read = readBlock;
        buffer = new ubyte[initial*chunkSize]; //TODO: revisit with std.allocator
        marks = new typeof(marks)();
        fillBuffer(0);
    }

    @disable this(this);

    @property ubyte front()
    in {
        assert(!empty);
    }
    body {
        return buffer[cur];
    }

    @property bool empty() { return !has(1); }

    void popFront() {
        cur++; 
        if(cur == buffer.length && !last)
            refill();
    }

    ubyte opIndex(size_t idx) {
        has(idx+1);
        return buffer[cur+idx];
    }

    @property bool has(size_t n) {
        if (buffer.length < cur + n) {
            if (last)
                return false;
            refill(n);
            //refill should get us the required length        
            return buffer.length >= cur + n;
        }
        return true;
    }    

    private void refill(size_t extra=1)
    in {
        assert(!last);
    }
    body {
        //number of full blocks at front of buffer till first pinned by marks
        // or till 'cur' that is to be considered as pinned
        auto start = marks.empty ? cur & ~(chunkSize-1) : 
                chunkSize*(marks.front - cast(size_t)(mileage/chunkSize));
        if (start >= extra + chunkSize-1) {
            copy(buffer[start..$], buffer[0..$-start]);
            mileage += start;
            cur -= start;
            //all after buffer.length - start is free space
            fillBuffer(buffer.length - start);
        }
        else {
            // compaction won't help
            // make sure we'd get at least extra bytes to read
            auto oldLen = buffer.length;
            buffer.length = max(cur + extra, 
                buffer.length * 14 / 10  & ~(chunkSize-1));
            fillBuffer(oldLen);
            //no compaction - no mileage
        }
    }

    // read up to the end of buffer, starting at start; shorten on last read
    void fillBuffer(size_t start)
    {
        size_t got = read(buffer[start..$]);
        if (got + start < buffer.length) {
            last = true;
            buffer = buffer[0..got+start];
        }
    }

    size_t offset(ref Mark m) {
        return cast(size_t)(m.pos - mileage);
    }

    @property Mark mark() {
        auto m = Mark(mileage+cur, &this);
        auto blk = cast(size_t)(m.pos/chunkSize);
        if(blk in counts) //hash is O(1)
            counts[blk]++;
        else {
            marks.insert(blk);
            counts[blk] = 1;
        }
        return m;
    }

    ubyte[] slice(ref Mark m) {
        return buffer[offset(m)..cur];
    }

    void restore(ref Mark m) {
        cur = cast(size_t)(m.pos - mileage);
    }

    //
    void discard(ulong ofs) {
        auto blk = cast(size_t)(ofs / chunkSize);
        if(--counts[blk] == 0) {
            marks.remove(marks.equalRange(blk));
            counts.remove(blk);
        }
    }
    import std.container;
    //any good set structure would do (preferably for small sets)
    RedBlackTree!(size_t) marks;
    //AA mark -> num of marks to the same chunk
    uint[size_t] counts;
    size_t delegate(ubyte[]) read;
    ubyte[] buffer; //bit enough to contain all present marks
    size_t cur; //current position    
    size_t chunkSize;
    ulong mileage; //bytes discarded before curent buffer.ptr
    bool last; // no more bytes to read
}

static assert(isBuffer!(GenericBuffer));

auto genericBuffer(size_t delegate(ubyte[]) reader, size_t chunk=1024, size_t n=8)
{
    return GenericBuffer(reader, chunk, n);
}

unittest
{
    import std.conv;
    ubyte[] arr = iota(cast(ubyte)10, cast(ubyte)100).array;
    //simple stream - slice a piece of array 
    auto buf = genericBuffer((ubyte[] target){
        auto toCopy = min(target.length, arr.length);
        target[0..toCopy] = arr[0..toCopy];
        arr = arr[toCopy..$];
        return toCopy;
    }, 4, 2);
    assert(!buf.empty);
    assert(buf.front == 10);
    assert(buf.has(20));
    foreach(v; 10..40){
        assert(buf.front == v, text(buf.front, " vs ", v));
        assert(v + 2 >= 40 || buf[2] == v+2);
        assert(v + 5 >= 40 || buf[5] == v+5);
        buf.popFront();
    }
    {
        auto m = buf.mark();
        auto m2 = buf.mark();
        foreach(v; 40..70) {
            assert(buf.front == v);
            buf.popFront();
        }
        assert(equal(buf.slice(m2), buf.slice(m)));
        assert(equal(buf.slice(m), iota(40, 70)));
    }
    auto m = buf.mark();
    assert(equal(&buf, iota(70, 100)));
    buf.restore(m);
    assert(equal(&buf, iota(70, 100)));
    assert(equal(buf.slice(m), iota(70, 100)));
}