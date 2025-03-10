import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Timer "mo:base/Timer";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import StableTrieMap "mo:StableTrieMap";
import Types "../types/NewsTypes";
import Utils "../common/Utils";

actor class NewsIndex(news_canister_id: Principal) = this{

    stable let index_store = StableTrieMap.new<Text, (Principal,Nat)>();

    stable let _category_index_store = StableTrieMap.new<Text, [(Principal,Nat,Text)]>();
    stable let _tag_index_store = StableTrieMap.new<Text, [(Principal,Nat,Text)]>();

    stable let sync_info_store = StableTrieMap.new<Principal, Nat>();


    private func _sync_index() : async () {
        // query all news archive canister
        let news_canister : Types.NewsInterface = actor(Principal.toText(news_canister_id));
        let archives = await news_canister.get_archives();  
        //loop all news archive canister
        switch(archives){
            case(#ok(archives)){
                label _loop for(archive in archives.vals()){
                    let canister_id = Principal.fromActor(archive.canister);
                    //get sync info from sync_info_store
                    let sync_index = StableTrieMap.get(sync_info_store, Principal.equal, Principal.hash, canister_id);
                    let begin_index = switch(sync_index){
                        case(null){
                            //sync info not found, set to 0
                            archive.start;
                        };
                        case(?last_index){
                            //sync info found, set to sync_info
                            last_index;
                        };
                    };

                    if(begin_index >= archive.end){
                        continue _loop;
                    };

                    let news = await archive.canister.query_news({start = begin_index; length = 1000});
                    if(news.news.size() == 0){
                        continue _loop;
                    };
                    for(news_item in news.news.vals()){
                        StableTrieMap.put(index_store, Text.equal, Text.hash, news_item.hash, (canister_id, news_item.index));
                        switch(StableTrieMap.get(_category_index_store, Text.equal, Text.hash, news_item.category)){
                            case(null){
                                StableTrieMap.put(_category_index_store, Text.equal, Text.hash, news_item.category, [(canister_id, news_item.index, news_item.hash)]);
                            };
                            case(?category_index){
                                StableTrieMap.put(_category_index_store, Text.equal, Text.hash, news_item.category, Array.append(category_index, [(canister_id, news_item.index, news_item.hash)]));
                            };
                        };
                        for(tag in news_item.tags.vals()){
                            switch(StableTrieMap.get(_tag_index_store, Text.equal, Text.hash, tag)){
                                case(null){
                                StableTrieMap.put(_tag_index_store, Text.equal, Text.hash, tag, [(canister_id, news_item.index, news_item.hash)]);
                            };
                            case(?tag_index){
                                StableTrieMap.put(_tag_index_store, Text.equal, Text.hash, tag, Array.append(tag_index, [(canister_id, news_item.index, news_item.hash)]));
                                };
                            };
                        };
                    };
                    //update sync info
                    StableTrieMap.put(sync_info_store, Principal.equal, Principal.hash, canister_id, news.news[news.news.size() - 1].index);
                };
            };
            case(#err(_err)){
                return;
            };
        };
    };

    public composite query func get_news_by_hash(news_hash: Text): async  Result.Result<Types.News, Types.Error> {
        let news_index = StableTrieMap.get(index_store, Text.equal, Text.hash, news_hash);
        switch(news_index){
            case null {
                //query from news canister
                let news_canister : Types.NewsInterface = actor(Principal.toText(news_canister_id));
                let news = await news_canister.get_news_by_hash(news_hash);
                return news;
            };
            case (?(archive_id,index)) {
                let news_from_archive : Types.ArchiveInterface = actor (Principal.toText(archive_id));
                let news = await news_from_archive.get_news(index);
                return news;
            };
        };
    };

    public composite query func query_news_by_category(category: Text, offset: Nat, limit: Nat): async Result.Result<Types.Page<Types.News>, Types.Error> {
        if(limit > 100){
            return #err(#InvalidRequest("Limit must be less than 100"));
        };
        // Fetch from container news with the actual offset and limit
        let news_canister : Types.NewsInterface = actor(Principal.toText(news_canister_id));
        let containerNewsResult = await news_canister.query_news_by_category(category, offset, limit);
        // Get archived news count from container index (index store)
        let news_index = StableTrieMap.get(_category_index_store, Text.equal, Text.hash, category);
        
        let containerIndexCount = switch(news_index) {
            case (null) { 0 };
            case (?news_index_array) { news_index_array.size() };
        };
        
        let containerNewsCount = switch(containerNewsResult) {
            case (#ok(page)) { page.totalElements };
            case (#err(_)) { 0 };
        };
        
        let totalCount = containerNewsCount + containerIndexCount;
        
        // If offset is beyond total count, return empty result
        if (offset >= totalCount) {
            return #ok({
                content = [];
                totalElements = totalCount;
                limit = limit;
                offset = offset;
            });
        };
        
        // Calculate how many items to fetch from container news
        let itemsFromNews = if (offset < containerNewsCount) {
            Nat.min(limit, containerNewsCount - offset);
        } else {
            0
        };
        
        // Calculate offset for container index if needed
        let offsetForIndex = if (offset >= containerNewsCount) {
            Nat.sub(offset, containerNewsCount);
        } else {
            0
        };
        
        // Calculate how many items to fetch from container index
        let itemsFromIndex = Nat.min(limit - itemsFromNews, containerIndexCount - offsetForIndex);
        
        // Use the results from container news if already fetched
        var containerNewsResults : [Types.News] = [];
        if (itemsFromNews > 0) {
            switch(containerNewsResult) {
                case(#err(err)) {
                    return #err(err);
                };
                case(#ok(page)) {
                    containerNewsResults := page.content;
                };
            };
        };
        
        // Fetch from container index if needed
        var containerIndexResults : [Types.News] = [];
        if (itemsFromIndex > 0 and itemsFromIndex <= limit) {
            switch(news_index) {
                case (null) {};
                case (?news_index_array) {
                    let reverse_index_array = Array.reverse(news_index_array);
                    let index_array = Utils.arrayRange(reverse_index_array, offsetForIndex, itemsFromIndex);
                    let buffer = Buffer.Buffer<Types.News>(0);
                    
                    for((archive_id, index, hash) in index_array.vals()) {
                        let news_from_archive : Types.ArchiveInterface = actor(Principal.toText(archive_id));
                        let news = await news_from_archive.get_news(index);
                        switch(news) {
                            case(#ok(news)) {
                                buffer.add(news);
                            };
                            case(#err(_)) {};
                        };
                    };
                    
                    containerIndexResults := Buffer.toArray(buffer);
                };
            };
        };
        
        // Combine results
        let combinedResults = Array.append<Types.News>(containerNewsResults, containerIndexResults);
        
        return #ok({
            content = combinedResults;
            limit = limit;
            offset = offset;
            totalElements = totalCount;
        });
    };


    public composite query func query_news_by_tag(tag: Text, offset: Nat, limit: Nat): async Result.Result<Types.Page<Types.News>, Types.Error> {
        if(limit > 100){
            return #err(#InvalidRequest("Limit must be less than 100"));
        };
        // Fetch from container news with the actual offset and limit
        let news_canister : Types.NewsInterface = actor(Principal.toText(news_canister_id));
        let containerNewsResult = await news_canister.query_news_by_tag(tag, offset, limit);
        // Get archived news count from container index (index store)
        let news_index = StableTrieMap.get(_tag_index_store, Text.equal, Text.hash, tag);
        
        let containerIndexCount = switch(news_index) {
            case (null) { 0 };
            case (?news_index_array) { news_index_array.size() };
        };
        
        let containerNewsCount = switch(containerNewsResult) {
            case (#ok(page)) { page.totalElements };
            case (#err(_)) { 0 };
        };
        
        let totalCount = containerNewsCount + containerIndexCount;
        
        // If offset is beyond total count, return empty result
        if (offset >= totalCount) {
            return #ok({
                content = [];
                totalElements = totalCount;
                limit = limit;
                offset = offset;
            });
        };
        
        // Calculate how many items to fetch from container news
        let itemsFromNews = if (offset < containerNewsCount) {
            Nat.min(limit, containerNewsCount - offset);
        } else {
            0
        };
        
        // Calculate offset for container index if needed
        let offsetForIndex = if (offset >= containerNewsCount) {
            Nat.sub(offset, containerNewsCount);
        } else {
            0
        };
        
        // Calculate how many items to fetch from container index
        let itemsFromIndex = Nat.min(limit - itemsFromNews, containerIndexCount - offsetForIndex);
        
        // Use the results from container news if already fetched
        var containerNewsResults : [Types.News] = [];
        if (itemsFromNews > 0) {
            switch(containerNewsResult) {
                case(#err(err)) {
                    return #err(err);
                };
                case(#ok(page)) {
                    containerNewsResults := page.content;
                };
            };
        };
        
        // Fetch from container index if needed
        var containerIndexResults : [Types.News] = [];
        if (itemsFromIndex > 0 and itemsFromIndex <= limit) {
            switch(news_index) {
                case (null) {};
                case (?news_index_array) {
                    let reverse_index_array = Array.reverse(news_index_array);
                    let index_array = Utils.arrayRange(reverse_index_array, offsetForIndex, itemsFromIndex);
                    let buffer = Buffer.Buffer<Types.News>(0);
                    
                    for((archive_id, index, hash) in index_array.vals()) {
                        let news_from_archive : Types.ArchiveInterface = actor(Principal.toText(archive_id));
                        let news = await news_from_archive.get_news(index);
                        switch(news) {
                            case(#ok(news)) {
                                buffer.add(news);
                            };
                            case(#err(_)) {};
                        };
                    };
                    
                    containerIndexResults := Buffer.toArray(buffer);
                };
            };
        };
        
        // Combine results
        let combinedResults = Array.append<Types.News>(containerNewsResults, containerIndexResults);
        
        return #ok({
            content = combinedResults;
            limit = limit;
            offset = offset;
            totalElements = totalCount;
        });
    };

    // private func _query_news(news_index: ?[(Principal,Nat,Text)],containerNewsResult : Result.Result<Types.Page<Types.News>, Types.Error>, offset: Nat, limit: Nat): async Result.Result<Types.Page<Types.News>, Types.Error> {
        
    // };


    ignore Timer.recurringTimer<system>(#seconds(60 * 1), _sync_index);

}

