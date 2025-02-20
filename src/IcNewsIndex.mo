import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Timer "mo:base/Timer";
import StableTrieMap "mo:StableTrieMap";
import Types "/types/Types";

actor class NewsIndex(news_canister_id: Principal) = this{

    stable let index_store = StableTrieMap.new<Text, (Principal,Nat)>();

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
                let news_canister : Types.NewsInterface = actor("aaaaa-aa");
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


    ignore Timer.recurringTimer<system>(#seconds(60 * 1), _sync_index);

}

