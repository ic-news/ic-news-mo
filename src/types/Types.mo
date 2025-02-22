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
        #InternalError : Text;
        #NotController;
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
        pid: Principal;
        alias: Text;
    };

    public type Category = {
        name: Text;
        metadata: ?Value;
    };

    public type Tag = {
        name: Text;
        metadata: ?Value;
    };

    public type AddCategoryArgs = {
        args: [Category];
    };

    public type AddTagArgs = {
        args: [Tag];
    };


    public type News = {
        index: Nat;
        provider: Value;
        id: ?Text;
        hash: Text;
        title: Text;
        description: Text;
        metadata: Value;
        category: Text;
        tags: [Text];
        created_at: Nat;
    };

    public type AddNewsArgs = {
        args: [News];
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
        append_news : shared ([News]) -> async Result.Result<Bool, Error>;
        total_news : query () -> async Result.Result<Nat, Error>;
        query_news : query (NewsRequest) -> async NewsRange;
        remaining_capacity : query () -> async Result.Result<Nat, Error>;
        get_news : query (Nat) -> async Result.Result<News, Error>;
    };

    public type NewsInterface = actor {
        add_categories : shared (AddCategoryArgs) -> async Result.Result<Bool, Error>;
        add_tags : shared (AddTagArgs) -> async Result.Result<Bool, Error>;
        add_news : shared (AddNewsArgs) -> async Result.Result<Bool, Error>;
        get_archives : query () -> async Result.Result<[ArchiveData], Error>;
        get_categories : query () -> async Result.Result<[Category], Error>;
        get_tags : query () -> async Result.Result<[Tag], Error>;
        query_news : query (NewsRequest) -> async NewsResponse;
        query_latest_news : query (Nat) -> async Result.Result<[News], Error>;
        get_news_by_hash : query (Text) -> async Result.Result<News, Error>;
        get_news_by_index : query (Nat) -> async Result.Result<News, Error>;
        get_news_by_time : query (Nat, Nat) -> async Result.Result<[News], Error>;
    };

}