import Hash "mo:base/Hash";
import Nat32 "mo:base/Nat32";
module{

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