import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Debug "mo:base/Debug";
import Array "mo:base/Array";
import Nat64 "mo:base/Nat64";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import Region "mo:base/Region";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Itertools "mo:itertools/Iter";
import StableTrieMap "mo:StableTrieMap";
import Types "../types/NewsTypes";
import Utils "../common/Utils";

shared (initMsg) actor class Archive() = this {
    type MemoryBlock = {
        offset : Nat64;
        size : Nat;
    };

    stable let KiB = 1024;
    stable let GiB = KiB ** 3;
    stable let MEMORY_PER_PAGE : Nat64 = Nat64.fromNat(64 * KiB);
    stable let MIN_PAGES : Nat64 = 32; // 2MiB == 32 * 64KiB
    stable var PAGES_TO_GROW : Nat64 = 2048; // 64MiB
    stable let MAX_MEMORY = 64 * GiB;

    stable let BUCKET_SIZE = 1000;
    stable let MAX_TRANSACTIONS_PER_REQUEST = 5000;

    stable var news_region : Region = Region.new();
    stable var memory_pages : Nat64 = Region.size(news_region);
    stable var total_memory_used : Nat64 = 0;

    stable var filled_buckets = 0;
    stable var trailing_blocks = 0;
    stable let news_store = StableTrieMap.new<Nat, [MemoryBlock]>();


    public shared ({ caller }) func append_news(newses : [Types.News]) : async Result.Result<Bool, Types.Error> {
        if (not Principal.isController(caller)) {
            return #err(#InternalError("Unauthorized Access: Can not access this archive canister"));
        };
        if(newses.size() == 0) return #ok(true);
        let buffer = Buffer.Buffer<Types.News>(newses.size());
        for(news in newses.vals()){
            buffer.add(news);
        };

        let blocks = Buffer.toArray(buffer);
        var blocks_iter = blocks.vals();

        if (trailing_blocks > 0) {
            let last_bucket = StableTrieMap.get(
                news_store,
                Nat.equal,
                Utils.hash,
                filled_buckets,
            );

            switch (last_bucket) {
                case (?last_bucket) {
                    let new_bucket = Iter.toArray(
                        Itertools.take(
                            Itertools.chain(
                                last_bucket.vals(),
                                Iter.map(blocks.vals(), _store_data),
                            ),
                            BUCKET_SIZE,
                        )
                    );

                    if (new_bucket.size() == BUCKET_SIZE) {
                        let offset = (BUCKET_SIZE - last_bucket.size()) : Nat;

                        blocks_iter := Itertools.fromArraySlice(blocks, offset, blocks.size());
                    } else {
                        blocks_iter := Itertools.empty();
                    };

                    _store_bucket(new_bucket);
                };
                case (_) {};
            };
        };

        for (chunk in Itertools.chunks(blocks_iter, BUCKET_SIZE)) {
            _store_bucket(Array.map(chunk, _store_data));
        };

        #ok(true);
    };

    public query func total_news() : async Result.Result<Nat, Types.Error> {
        return #ok(_total_news());
    };

    private func _total_news() : Nat {
        (filled_buckets * BUCKET_SIZE) + trailing_blocks;
    };

    public query func get_news(block_index : Nat) : async Result.Result<Types.News, Types.Error> {
        let news = _get_news(block_index);
        switch(news){
            case(null){
                return #err(#InternalError("News not found"));
            };
            case(?news){
                return #ok(news);
            };
        };
    };

    private func _get_news(block_index : Nat) : ?Types.News {
        let bucket_key = block_index / BUCKET_SIZE;

        let opt_bucket = StableTrieMap.get(
            news_store,
            Nat.equal,
            Utils.hash,
            bucket_key,
        );

        switch (opt_bucket) {
            case (?bucket) {
                let i = block_index % BUCKET_SIZE;
                if (i < bucket.size()) {
                    ?_get_data(bucket[block_index % BUCKET_SIZE]);
                } else {
                    null;
                };
            };
            case (_) {
                null;
            };
        };
    };

    public query func query_news(req : Types.NewsRequest) : async Types.NewsRange {
        return _query_news(req.start, req.length);
    };

    private func _query_news(start : Nat, length : Nat) : Types.NewsRange {
        var iter = Itertools.empty<MemoryBlock>();

        let end = start + length;
        let start_bucket = start / BUCKET_SIZE;
        let end_bucket = (Nat.min(end, _total_news()) / BUCKET_SIZE) + 1;

        label _loop for (i in Itertools.range(start_bucket, end_bucket)) {
            let opt_bucket = StableTrieMap.get(
                news_store,
                Nat.equal,
                Utils.hash,
                i,
            );

            switch (opt_bucket) {
                case (?bucket) {
                    if (i == start_bucket) {
                        iter := Itertools.fromArraySlice(bucket, start % BUCKET_SIZE, Nat.min(bucket.size(), (start % BUCKET_SIZE) +length));
                    } else if (i + 1 == end_bucket) {
                        let bucket_iter = Itertools.fromArraySlice(bucket, 0, end % BUCKET_SIZE);
                        iter := Itertools.chain(iter, bucket_iter);
                    } else {
                        iter := Itertools.chain(iter, bucket.vals());
                    };
                };
                case (_) { break _loop };
            };
        };

        let news = Iter.toArray(
            Iter.map(
                Itertools.take(iter, MAX_TRANSACTIONS_PER_REQUEST),
                _get_data,
            )
        );

        { news };
    };

    public query func remaining_capacity() : async Result.Result<Nat, Types.Error> {
        return #ok(MAX_MEMORY - Nat64.toNat(total_memory_used));
    };

    public query func get_cycle_balance() : async Result.Result<Nat, Types.Error> {
        return #ok(Cycles.balance());
    };

    private func _to_blob(tx : Types.News) : Blob {
        to_candid (tx);
    };

    private func _from_blob(tx : Blob) : Types.News {
        switch (from_candid (tx) : ?Types.News) {
            case (?tx) tx;
            case (_) Debug.trap("Could not decode tx blob");
        };
    };

    private func _store_data(tx : Types.News) : MemoryBlock {
        let blob = _to_blob(tx);

        if ((memory_pages * MEMORY_PER_PAGE) - total_memory_used < (MIN_PAGES * MEMORY_PER_PAGE)) {
            ignore Region.grow(news_region, PAGES_TO_GROW);
            memory_pages += PAGES_TO_GROW;
        };

        let offset = total_memory_used;

        Region.storeBlob(
            news_region,
            offset,
            blob,
        );

        let mem_block = {
            offset;
            size = blob.size();
        };

        total_memory_used += Nat64.fromNat(blob.size());
        mem_block;
    };

    private func _get_data({ offset; size } : MemoryBlock) : Types.News {
        let blob = Region.loadBlob(news_region, offset, size);

        _from_blob(blob);
    };

    private func _store_bucket(bucket : [MemoryBlock]) {

        StableTrieMap.put(
            news_store,
            Nat.equal,
            Utils.hash,
            filled_buckets,
            bucket,
        );

        if (bucket.size() == BUCKET_SIZE) {
            filled_buckets += 1;
            trailing_blocks := 0;
        } else {
            trailing_blocks := bucket.size();
        };
    };
};