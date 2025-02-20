import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Float "mo:base/Float";
import Bool "mo:base/Bool";
import Result "mo:base/Result";

module {

    public type Error = {
        #CommonError;
        #InsufficientFunds;
        #InternalError : Text;
        #NotController;
        #NotAdmin;
        #InvalidRequest;
    };

    public type Value = {
        #Text : Text;
        #Nat : Nat;
        #Int : Int;
        #Float : Float;
        #Bool : Bool;
        #Blob : Blob;
        #Array : [Value];
        #Map : [(Text, Value)];
        #Principal : Principal;
    };

    public type Provider = {
        principal: Principal;
        name: Text;
    };

    public type NewsArg = {
        id: Text;
        hash: Text;
        title: Text;
        url: Text;
        description: Text;
        metadata: Value;
        category: Text;
        tags: [Text];
        created_at: Nat;
    };

    public type NewsArgs = [NewsArg];

    public type News = {
        index: Nat;
        provider: Provider;
        id: Text;
        hash: Text;
        title: Text;
        url: Text;
        description: Text;
        metadata: Value;
        category: Text;
        tags: [Text];
        created_at: Nat;
    };

    public type NewsRequest = {
        start: Nat;
        length: Nat;
    };

    public type NewsResponse = {
        length : Nat;
        first_index : Nat;
        news : [News];
        archived_news : [ArchivedNews];
    };

    public type ArchivedNews = {
        start : Nat;
        length : Nat;
        callback : QueryArchivedNewsFn;
    };

    public type NewsRange = {
        news : [News];
    };

     public type ArchiveData = {
        canister : ArchiveInterface;
        stored_news : Nat;
        start : Nat;
        end : Nat;
    };

    public type QueryArchivedNewsFn = shared query (NewsRequest) -> async NewsRange;


    public type ArchiveInterface = actor {
        append_news : shared ([NewsArg]) -> async Result.Result<Bool, Error>;
        total_news : query () -> async Result.Result<Nat, Error>;
        query_news : query (NewsRequest) -> async NewsRange;
        remaining_capacity : query () -> async Result.Result<Nat, Error>;
        get_news : query (Nat) -> async Result.Result<News, Error>;
    };

    public type NewsInterface = actor {
        add_news : shared (NewsArg) -> async Result.Result<Bool, Error>;
        get_archives : query () -> async Result.Result<[ArchiveData], Error>;
        query_news : query (NewsRequest) -> async NewsResponse;
        query_latest_news : query (Nat) -> async Result.Result<[News], Error>;
        get_news_by_hash : query (Text) -> async Result.Result<News, Error>;
        get_news_by_index : query (Nat) -> async Result.Result<News, Error>;
        get_news_by_time : query (Nat, Nat) -> async Result.Result<[News], Error>;
    };

    // public type IndexInterface = actor {
    //     register_index : shared (Text) -> async Result.Result<Bool, Error>;
    // };

    // public type GovernanceInterface = actor {
    //     get_storage_canister_id : query (month: Nat) -> async Result.Result<Principal, Error>; 
    //     get_all_storage : query () -> async Result.Result<[(Nat, StorageInfo)], Error>;
    // };

    // public type RootInterface = actor {
    //     add_storage_canister : shared (canister_id: Principal, month: Nat) -> async Result.Result<Bool, Error>;
    //     add_index_canister : shared (canister_id: Principal, name: Text) -> async Result.Result<Bool, Error>;
    // };
    
}