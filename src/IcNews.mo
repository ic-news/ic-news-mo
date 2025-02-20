import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Buffer "mo:base/Buffer";
import Bool "mo:base/Bool";
import Order "mo:base/Order";
import Iter "mo:base/Iter";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Array "mo:base/Array";
import Timer "mo:base/Timer";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import StableTrieMap "mo:StableTrieMap";
import Types "/types/Types";
import Archive "Archive";

actor class News() = this{

    stable let provider_store = StableTrieMap.new<Principal, Text>();

    stable var _news_array : [Types.News] = [];
    var _news_buffer = Buffer.Buffer<Types.News>(0);

    stable var archives : [Types.ArchiveData] = [];

    stable var _index : Nat = 0;
    let DEPLOY_CANISTER_CYCLE = 300_000_000_000;

    
    private func _save_to_archive() : async () {
        let total = _news_buffer.size();
        if(total > 12000){
            let news_list = Buffer.toArray(_news_buffer);
            //sort news_list by created_at asc
            let sortedArray = Array.sort(news_list, func(a: Types.News, b: Types.News) : Order.Order {
                Nat.compare(a.created_at, b.created_at)
            });
            let _append_array = Array.subArray(sortedArray,0,1999);
            let _remain_array = Array.subArray(sortedArray,2000,Nat.sub(total,1));
            _news_buffer := Buffer.fromArray<Types.News>(_remain_array);

            //get last archive from archives
            var last_archive : Types.ArchiveInterface = actor("aaaaa-aa");
            var is_deployed = false;
            if(archives.size() > 0){
                last_archive := archives[archives.size() - 1].canister;
                let remaining_capacity = await last_archive.remaining_capacity();
                switch(remaining_capacity){
                    case(#ok(remaining_capacity)){
                            if(remaining_capacity <= 100*1024*1024){
                                let archive = await deploy_archive_canister();
                                last_archive := archive;
                                is_deployed := true;
                            };
                    };
                    case(#err(_err)){
                        //ignore
                    };
                };
            }else{
                //deploy new archive
                let archive = await deploy_archive_canister();
                last_archive := archive;
                is_deployed := true;
            };
            let _ = await last_archive.append_news(_append_array);
            if(is_deployed){
                //append new archive to archives
                let archive : Types.ArchiveData = { 
                    canister = last_archive;
                    stored_news = total;
                    start = _index;
                    end = _index + 1999;
                };
                archives := Array.append(archives, [archive]);
            }else{
                //update last archive
                let archive : Types.ArchiveData = { 
                    canister = last_archive;
                    stored_news = total;
                    start = _index;
                    end = _index + 1999;
                };

                let new_archive = {
                    archive with
                    start = _index;
                };

                let new_archives = Array.append(Array.subArray(archives, 0, Nat.sub(archives.size(), 1)), [archive]);
                archives := new_archives;
            };
        };
    };

    private func deploy_archive_canister() : async Types.ArchiveInterface {
        let cycles_balance = Cycles.balance();
        if (cycles_balance < DEPLOY_CANISTER_CYCLE) {
            throw Error.reject("Cycle: Insufficient cycles balance");
        };
        Cycles.add<system>(DEPLOY_CANISTER_CYCLE);
        let archive_canister = await Archive.Archive();
        let archive_canister_id = Principal.fromActor(archive_canister);
        return actor(Principal.toText(archive_canister_id));
    };

    public query func get_archives(): async  Result.Result<[Types.ArchiveData], Types.Error> {
        return #ok(archives);
    };

    public shared(msg) func add_provider(provider: Types.Provider): async  Result.Result<Bool, Types.Error> {
        if(Principal.isController(msg.caller)){
            StableTrieMap.put(provider_store, Principal.equal, Principal.hash, provider.principal, provider.name);
            return #ok(true);
        } else {
            return #err(#InternalError("Access denied"));
        };
    };

    public query func get_providers(): async  Result.Result<[(Principal,Text)], Types.Error> {
        let providers = StableTrieMap.entries(provider_store);
        let provider_list = Iter.toArray(providers);
        return #ok(provider_list);
    };

    public shared(msg) func add_news(news: Types.NewsArgs): async  Result.Result<Bool, Types.Error> {
        let provider = StableTrieMap.get(provider_store, Principal.equal, Principal.hash, msg.caller);
        switch(provider){
            case null {
                return #err(#InternalError("Provider not found"));
            };
            case (?provider) {
                for(news_arg in news.vals()){
                    let news_item : Types.News = {news_arg with
                        index = _index;
                        provider = {
                            principal = msg.caller;
                            name = provider;
                        };
                    };
                    _news_buffer.add(news_item);
                    _index += 1;
                };
            };
        };
        return #ok(true);
    };

    public composite query func query_news(req: Types.NewsRequest): async  Types.NewsResponse {
        let news_list = Buffer.toArray(_news_buffer);
        var first_index = 0;
        if (news_list.size() != 0) {
            first_index := news_list[0].index;
        };

        let req_end = req.start + req.length;

        var news_in_canister : [Types.News] = [];
        let buffer = Buffer.Buffer<Types.News>(req.length);
        if (req_end > first_index) {
            for(news_item in news_list.vals()){
                if(news_item.index >= req.start and news_item.index < req_end){
                    buffer.add(news_item);
                };
            };
            news_in_canister := Buffer.toArray(buffer);
        };
        var req_length = req.length;
        if (req.length > news_in_canister.size()) {
            req_length := req.length - news_in_canister.size();
        };

        let archive_news = Buffer.Buffer<Types.ArchivedNews>(archives.size());
        let tmp_archives = archives;
        var first_archive = true;
        var tmp_archives_length = 0;
        for (archive in tmp_archives.vals()) {
            var start = 0;
            var end = 0;
            if (tmp_archives_length < req_length) {
                if (first_archive) {
                    if (req.start <= archive.end) {
                        start := req.start - archive.start;
                        end := Nat.min(archive.end - archive.start + 1, req_length - tmp_archives_length) - start;
                        first_archive := false;
                    };
                } else {
                    if (req.start < archive.start or req_length <= archive.end) {
                        end := Nat.min(archive.end - archive.start + 1, req_length - tmp_archives_length) - start;
                    };
                };
                tmp_archives_length += end;
                if (start != 0 or end != 0) {
                    let callback = archive.canister.query_news;
                    archive_news.add({ start; length = end; callback });
                };
            };
        };
        {
            length = total_news();
            first_index;
            news = news_in_canister;
            archived_news = Buffer.toArray(archive_news);
        };
    };

    private func total_news() : Nat {
        var total = 0;
        for(archive in archives.vals()){
            total += archive.stored_news;
        };
        return total + _news_buffer.size();
    };

    public query func query_latest_news(size: Nat): async  Result.Result<[Types.News], Types.Error> {
        let news_list = Buffer.toArray(_news_buffer);
        let sortedArray = Array.sort(news_list, func(a: Types.News, b: Types.News) : Order.Order {
            Nat.compare(a.created_at, b.created_at)
        });
        let buffer = Buffer.Buffer<Types.News>(size);
        for(news_item in sortedArray.vals()){
            if(buffer.size() < size){
                buffer.add(news_item);
            };
        };
        return #ok(Buffer.toArray(buffer));
    };

    public query func get_news_by_hash(hash: Text): async  Result.Result<Types.News, Types.Error> {
        let news_list = Buffer.toArray(_news_buffer);
        for(news_item in news_list.vals()){
            if(news_item.hash == hash){
                return #ok(news_item);
            };
        };
        return #err(#InternalError("News not found"));
    };

    public composite query func get_news_by_index(index: Nat): async  Result.Result<Types.News, Types.Error> {
        let news_list = Buffer.toArray(_news_buffer);
        for(news_item in news_list.vals()){
            if(news_item.index == index){
                return #ok(news_item);
            };
        };
        //query from archives
        for(archive in archives.vals()){
            let news = await archive.canister.get_news(index);
            switch(news){
                case(#ok(news)){
                    return #ok(news);
                };
                case(#err(_err)){
                    //ignore
                };
            };
        };
        return #err(#InternalError("News not found"));
    };

    public query func get_news_by_time(begin_time : Nat, size: Nat): async  Result.Result<[Types.News], Types.Error> {
        let buffer = Buffer.Buffer<Types.News>(size);
        let news_list = Buffer.toArray(_news_buffer);
        let sortedArray = Array.sort(news_list, func(a: Types.News, b: Types.News) : Order.Order {
            Nat.compare(a.created_at, b.created_at)
        });
        label _loop for(news_item in sortedArray.vals()){
            if(news_item.created_at >= begin_time and buffer.size() < size){
                buffer.add(news_item);
            };
            if(buffer.size() >= size){
                break _loop;
            };
        };
        return #ok(Buffer.toArray(buffer));
    };

    system func preupgrade() {
        _news_array := Buffer.toArray(_news_buffer);
    };

    system func postupgrade() {
        _news_buffer := Buffer.fromArray<Types.News>(_news_array);
    };

    ignore Timer.recurringTimer<system>(#seconds(60 * 10), _save_to_archive);

}

