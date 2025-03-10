import Hash "mo:base/Hash";
import Nat32 "mo:base/Nat32";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";

module{

    public func arrayRemove<T>(arr: [T], item: T, equal: (T, T) -> Bool): [T] {
        var newArrayBuffer: Buffer.Buffer<T> = Buffer.Buffer<T>(0);
        for (t : T in arr.vals()) {
            if (not equal(t, item)) {newArrayBuffer.add(t);};
        };
        return Buffer.toArray(newArrayBuffer);
    };

    public func arrayRange<T>(arr: [T], offset: Nat, limit: Nat) : [T] {
        let size: Nat = arr.size();
        var newArrayBuffer: Buffer.Buffer<T> = Buffer.Buffer<T>(0);
        if(size == 0) { return Buffer.toArray(newArrayBuffer); };
        var end: Nat = offset + limit - 1;
        if (end > Nat.sub(size, 1)) {
            end := size - 1;
        };
        if (offset >= 0 and size > offset) {
            for (i in Iter.range(offset, end)) {
                newArrayBuffer.add(arr[i]);
            };
        };
        return Buffer.toArray(newArrayBuffer);
    };

    public func arrayContains<T>(arr: [T], item: T, equal: (T, T) -> Bool): Bool {
        for (t: T in arr.vals()) {
            if (equal(t, item)) {
                return true;
            };
        };
        return false;
    };

    public func _hash_nat8(key : [Nat32]) : Hash.Hash {
        var hash : Nat32 = 0;
        for (nat_of_key in key.vals()) {
            hash := hash +% nat_of_key;
            hash := hash +% hash << 10;
            hash := hash ^ (hash >> 6);
        };
        hash := hash +% hash << 3;
        hash := hash ^ (hash >> 11);
        hash := hash +% hash << 15;
        return hash;
    };

    public func hash(n : Nat) : Hash.Hash {
        let j = Nat32.fromNat(n);
        _hash_nat8([
            j & (255 << 0),
            j & (255 << 8),
            j & (255 << 16),
            j & (255 << 24),
        ]);
    };
}