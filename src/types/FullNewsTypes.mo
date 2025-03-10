import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Bool "mo:base/Bool";
import Result "mo:base/Result";
import Types "NewsTypes";
module {

    public type WebSocketValue = {
        #Common : Types.Value;
        #LatestNews : [FullNews];
        #NewsByIndex : FullNews;
        #NewsByHash : FullNews;
        #NewsByTime : [FullNews];
        #Categories : [Types.Category];
        #Tags : [Types.Tag];
        #Archives : [FullArchiveData];
    };

    public type FullNews = {
        index: Nat;
        provider: Types.Value;
        id: ?Text;
        hash: Text;
        title: Text;
        description: Text;
        content: Text;
        imageUrl: ?Text;
        metadata: Types.Value;
        category: Text;
        tags: [Text];
        created_at: Nat;
    };

    public type FullNewsArg = {
        id: ?Text;
        hash: Text;
        title: Text;
        description: Text;
        content: Text;
        imageUrl: ?Text;
        metadata: Types.Value;
        category: Text;
        tags: [Text];
        created_at: Nat;
    };

    public type AddFullNewsArgs = {
        args: [FullNewsArg];
    };

    public type NewsRequest = {
        start: Nat;
        length: Nat;
    };

    public type FullNewsResponse = {
        length : Nat;
        first_index : Nat;
        news : [FullNews];
        archived_news : [ArchivedFullNews];
    };

    public type ArchivedFullNews = {
        start : Nat;
        length : Nat;
        callback : shared query (NewsRequest) -> async FullNewsRange;
    };

    public type FullNewsRange = {
        news : [FullNews];
    };

    public type FullArchiveData = {
        canister : FullArchiveInterface;
        stored_news : Nat;
        start : Nat;
        end : Nat;
    };

    public type FullArchiveInterface = actor {
        append_news : shared ([FullNews]) -> async Result.Result<Bool, Types.Error>;
        total_news : query () -> async Result.Result<Nat, Types.Error>;
        query_news : query (NewsRequest) -> async FullNewsRange;
        remaining_capacity : query () -> async Result.Result<Nat, Types.Error>;
        get_news : query (Nat) -> async Result.Result<FullNews, Types.Error>;
    };

    public type FullNewsInterface = actor {
        add_categories : shared (Types.AddCategoryArgs) -> async Result.Result<Bool, Types.Error>;
        add_tags : shared (Types.AddTagArgs) -> async Result.Result<Bool, Types.Error>;
        add_news : shared (AddFullNewsArgs) -> async Result.Result<Bool, Types.Error>;
        get_archives : query () -> async Result.Result<[FullArchiveData], Types.Error>;
        get_categories : query () -> async Result.Result<[Types.Category], Types.Error>;
        get_tags : query () -> async Result.Result<[Types.Tag], Types.Error>;
        query_news : query (NewsRequest) -> async FullNewsResponse;
        query_latest_news : query (Nat) -> async Result.Result<[FullNews], Types.Error>;
        get_news_by_hash : query (Text) -> async Result.Result<FullNews, Types.Error>;
        get_news_by_index : query (Nat) -> async Result.Result<FullNews, Types.Error>;
        get_news_by_time : query (Nat, Nat) -> async Result.Result<[FullNews], Types.Error>;
    };

}