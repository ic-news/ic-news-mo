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
import Debug "mo:base/Debug";
import Time "mo:base/Time";
import Int "mo:base/Int";
import TrieSet "mo:base/TrieSet";
import Nat64 "mo:base/Nat64";
import StableTrieMap "mo:StableTrieMap";
import Types "../types/NewsTypes";
import Archive "Archive";
import Utils "../common/Utils";

import IcWebSocketCdk "mo:ic-websocket-cdk";
import IcWebSocketCdkState "mo:ic-websocket-cdk/State";
import IcWebSocketCdkTypes "mo:ic-websocket-cdk/Types";

actor class News() = this{

    stable let _provider_store = StableTrieMap.new<Principal, Text>();

    stable var _news_array : [Types.News] = [];
    var _news_buffer = Buffer.Buffer<Types.News>(0);

    stable var _category_array : [Types.Category] = [];

    stable var _tag_array : [Types.Tag] = [];

    stable var _archives : [Types.ArchiveData] = [];

    stable var _index : Nat = 0;
    let DEPLOY_CANISTER_CYCLE = 3_000_000_000_000;

    private var _last_error_message = "";
    private var _task_status = false;

    public query func get_task_status(): async  Result.Result<(Bool, Text), Types.Error> {
        return #ok((_task_status, _last_error_message));
    };

    public query func get_archives(): async  Result.Result<[Types.ArchiveData], Types.Error> {
        return #ok(_archives);
    };

    public query func get_providers(): async  Result.Result<[(Principal,Text)], Types.Error> {
        let providers = StableTrieMap.entries(_provider_store);
        let provider_list = Iter.toArray(providers);
        return #ok(provider_list);
    };

    public query func get_categories(): async  Result.Result<[Types.Category], Types.Error> {
        return #ok(_category_array);
    };

    public query func get_tags(): async  Result.Result<[Types.Tag], Types.Error> {
        return #ok(_tag_array);
    };

    public shared(msg) func add_provider(pid : Principal, alias : Text): async  Result.Result<Bool, Types.Error> {
        if(Principal.isController(msg.caller)){
            StableTrieMap.put(_provider_store, Principal.equal, Principal.hash, pid, alias);
            return #ok(true);
        } else {
            return #err(#InternalError("Access denied"));
        };
    };

    public shared(msg) func add_categories(categories: Types.AddCategoryArgs): async  Result.Result<Bool, Types.Error> {
        let provider = StableTrieMap.get(_provider_store, Principal.equal, Principal.hash, msg.caller);
        switch(provider){
            case null {
                return #err(#InternalError("Provider not found"));
            };
            case (?provider) {
                for(category in categories.args.vals()){
                    switch(Array.find<Types.Category>(_category_array, func(a: Types.Category): Bool {
                        a.name == category.name
                    })){
                        case null {
                            _category_array := Array.append(_category_array, [category]);
                        };
                        case (?_existing_category) {};
                    };
                };
            };
        };
        return #ok(true);
    };

    public shared(msg) func add_tags(tags: Types.AddTagArgs): async  Result.Result<Bool, Types.Error> {
        let provider = StableTrieMap.get(_provider_store, Principal.equal, Principal.hash, msg.caller);
        switch(provider){
            case null {
                return #err(#InternalError("Provider not found"));
            };
            case (?provider) {
                for(tag in tags.args.vals()){
                    switch(Array.find<Types.Tag>(_tag_array, func(a: Types.Tag): Bool {
                        a.name == tag.name
                    })){
                        case null {
                            _tag_array := Array.append(_tag_array, [tag]);
                        };
                        case (?_existing_tag) {};
                    };
                };
            };
        };
        return #ok(true);
    };

    public shared(msg) func add_news(news: Types.AddNewsArgs): async  Result.Result<Bool, Types.Error> {
        let provider = StableTrieMap.get(_provider_store, Principal.equal, Principal.hash, msg.caller);
        switch(provider){
            case null {
                return #err(#InternalError("Provider not found"));
            };
            case (?provider) {
                let buffer = Buffer.Buffer<Types.News>(news.args.size());
                for(news_arg in news.args.vals()){
                    let news_item : Types.News = {news_arg with
                        index = _index;
                        provider = #Map([("pid", #Principal(msg.caller)), ("alias", #Text(provider))]);
                    };
                    _news_buffer.add(news_item);
                    buffer.add(news_item);
                    _index += 1;
                };
                ignore send_to_all({
                        //topic is latest news
                        topic = "latest_news";
                        args = [];
                        result = #LatestNews(Buffer.toArray(buffer));
                        timestamp = Nat64.fromIntWrap(Time.now());
                    });
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

        let archive_news = Buffer.Buffer<Types.ArchivedNews>(_archives.size());
        let tmp_archives = _archives;
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
            length = _total_news();
            first_index;
            news = news_in_canister;
            archived_news = Buffer.toArray(archive_news);
        };
    };

    public query func total_news() : async  Result.Result<Nat, Types.Error> {
        return #ok(_total_news());
    };

    private func _total_news() : Nat {
        var total = 0;
        for(archive in _archives.vals()){
            total += archive.stored_news;
        };
        return total + _news_buffer.size();
    };

    public query func query_latest_news(size: Nat): async  Result.Result<[Types.News], Types.Error> {
        return #ok(_query_latest_news(size));
    };

    public query func query_news_by_category(category: Text, offset: Nat, limit: Nat): async  Result.Result<Types.Page<Types.News>, Types.Error> {
        return #ok(_query_news_by_category(category, offset, limit));
    };

    public query func query_news_by_tag(tag: Text, offset: Nat, limit: Nat): async  Result.Result<Types.Page<Types.News>, Types.Error> {
        return #ok(_query_news_by_tag(tag, offset, limit));
    };

    private func _query_news_by_category(category: Text, offset: Nat, limit: Nat):Types.Page<Types.News> {
        let news_list = Buffer.toArray(_news_buffer);
        //filter news by category
        let filteredArray = Array.filter(news_list, func(a: Types.News) : Bool {
            a.category == category
        });
        var sortedArray = Array.sort(filteredArray, func(a: Types.News, b: Types.News) : Order.Order {
            Nat.compare(b.index, a.index)
        });
        let result = Utils.arrayRange(sortedArray, offset, limit);
        return {
            content = result;
            limit = limit;
            offset = offset;
            totalElements = filteredArray.size();
        };
    };

    private func _query_news_by_tag(tag: Text, offset: Nat, limit: Nat):Types.Page<Types.News> {
        let news_list = Buffer.toArray(_news_buffer);
        //filter news by tag
        let filteredArray = Array.filter(news_list, func(a: Types.News) : Bool {
            Utils.arrayContains(a.tags, tag, Text.equal)
        });
        var sortedArray = Array.sort(filteredArray, func(a: Types.News, b: Types.News) : Order.Order {
            Nat.compare(b.index, a.index)
        });
        let result = Utils.arrayRange(sortedArray, offset, limit);
        return {
            content = result;
            limit = limit;
            offset = offset;
            totalElements = filteredArray.size();
        };
    };

    private func _query_latest_news(size: Nat):[Types.News] {
        let news_list = Buffer.toArray(_news_buffer);
        var sortedArray = Array.sort(news_list, func(a: Types.News, b: Types.News) : Order.Order {
            Nat.compare(a.index, b.index)
        });
        sortedArray := Array.reverse(sortedArray);
        let buffer = Buffer.Buffer<Types.News>(size);
        for(news_item in sortedArray.vals()){
            if(buffer.size() < size){
                buffer.add(news_item);
            };
        };
        return Buffer.toArray(buffer);
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
        for(archive in _archives.vals()){
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


    //websocket
    let params = IcWebSocketCdkTypes.WsInitParams(null, null);

    let ws_state = IcWebSocketCdkState.IcWebSocketState(params);

    type ClientPrincipal = IcWebSocketCdk.ClientPrincipal;

    type AppMessage = {
        topic : Text;
        args : [Text];
        result : Types.WebSocketValue;
        timestamp : Nat64;
    };

    var clients_connected : TrieSet.Set<ClientPrincipal> = TrieSet.empty();

    func on_open(args : IcWebSocketCdk.OnOpenCallbackArgs) : async () {
        Debug.print("On open called for client: " # debug_show (args));
        clients_connected := TrieSet.put(clients_connected, args.client_principal, Principal.hash(args.client_principal), Principal.equal);
        let msg : AppMessage = {
            topic = "connect";
            args = [];
            result = #Common(#Bool(true));
            timestamp = Nat64.fromIntWrap(Time.now());
        };
        await send_app_message(args.client_principal, msg);
    };

    func on_message(args : IcWebSocketCdk.OnMessageCallbackArgs) : async () {
        Debug.print("On message called for client: " # debug_show (args));
        let app_msg : ?AppMessage = from_candid (args.message);
        switch (app_msg) {
            case (null) {};
            case (?msg) {
                //check topic,return different message for different topic
                switch (msg.topic) {
                    case "get_latest_news" {
                        let new_msg : AppMessage = {
                            topic = msg.topic;
                            args = msg.args;
                            result = #LatestNews(_query_latest_news(2));
                            timestamp = Nat64.fromIntWrap(Time.now());
                        };
                        await send_app_message(args.client_principal, new_msg);
                    };
                    case "get_archives" {
                        let new_msg : AppMessage = {
                            topic = msg.topic;
                            args = msg.args;
                            result = #Archives(_archives);
                            timestamp = Nat64.fromIntWrap(Time.now());
                        };
                        await send_app_message(args.client_principal, new_msg);
                    };
                    case _{};
                };
            };
        };
    };

    func on_close(args : IcWebSocketCdk.OnCloseCallbackArgs) : async () {
        Debug.print("On close called for client: " # debug_show (args));
        clients_connected := TrieSet.delete(clients_connected, args.client_principal, Principal.hash(args.client_principal), Principal.equal);
    };

    func send_to_all(msg : AppMessage) : async () {
        let msg_bytes = to_candid (msg);
        let clients = TrieSet.toArray(clients_connected);
        if(clients.size() > 0){
            for(client in clients.vals()){
                switch (await IcWebSocketCdk.send(ws_state, client, msg_bytes)) {
                    case (#Err(_err)) {
                    };
                    case (#Ok(_)) {
                    };
                };
            };
        };
    };

    func send_app_message(to_principal : Principal, msg : AppMessage) : async () {
        let msg_bytes = to_candid (msg);
        switch (await IcWebSocketCdk.send(ws_state, to_principal, msg_bytes)) {
            case (#Err(_err)) {
            };
            case (#Ok(_)) {
            };
        };
    };

    let handlers = IcWebSocketCdkTypes.WsHandlers(
        ?on_open,
        ?on_message,
        ?on_close,
    );

    let ws = IcWebSocketCdk.IcWebSocket(ws_state, params, handlers);

    // method called by the WS Gateway after receiving FirstMessage from the client
    public shared ({ caller }) func ws_open(args : IcWebSocketCdk.CanisterWsOpenArguments) : async IcWebSocketCdk.CanisterWsOpenResult {
        Debug.print("Opening WS connection for client: " # debug_show (caller) # " with args: " # debug_show (args));
        await ws.ws_open(caller, args);
    };

    // method called by the Ws Gateway when closing the IcWebSocket connection
    public shared ({ caller }) func ws_close(args : IcWebSocketCdk.CanisterWsCloseArguments) : async IcWebSocketCdk.CanisterWsCloseResult {
        Debug.print("Closing WS connection for client: " # debug_show (caller) # " with args: " # debug_show (args));
        await ws.ws_close(caller, args);
    };

    // method called by the WS Gateway to send a message of type GatewayMessage to the canister
    public shared ({ caller }) func ws_message(args : IcWebSocketCdk.CanisterWsMessageArguments, msg_type : ?AppMessage) : async IcWebSocketCdk.CanisterWsMessageResult {
        Debug.print("Receiving message from client: " # debug_show (caller) # " with args: " # debug_show (args));
        await ws.ws_message(caller, args, msg_type);
    };

    // method called by the WS Gateway to get messages for all the clients it serves
    public shared query ({ caller }) func ws_get_messages(args : IcWebSocketCdk.CanisterWsGetMessagesArguments) : async IcWebSocketCdk.CanisterWsGetMessagesResult {
        Debug.print("Getting messages from client: " # debug_show (caller));
        Debug.print("Getting messages with args: " # debug_show (args));
        let result = ws.ws_get_messages(caller, args);
        Debug.print("Messages returned: " # debug_show (result));
        result;
    };

    //// Debug/tests methods
    // send a message to the client, usually called by the canister itself
    // public shared func send(client_principal : IcWebSocketCdk.ClientPrincipal, msg_bytes : Blob) : async IcWebSocketCdk.CanisterSendResult {
    //     Debug.print("Sending message to client: " # debug_show (client_principal));
    //     await ws.send(client_principal, msg_bytes);
    // };













    private func _save_to_archive() : async () {
        if(_task_status){
            return;
        };
        _task_status := true;
        try{
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
                var archive_data : Types.ArchiveData = { 
                        canister = last_archive;
                        stored_news = 0;
                        start = 0;
                        end = 0;
                };
                var is_deployed = false;
                if(_archives.size() > 0){
                    let last_archive_data = _archives[_archives.size() - 1];
                    last_archive := last_archive_data.canister;
                    let remaining_capacity = await last_archive.remaining_capacity();
                    switch(remaining_capacity){
                        case(#ok(remaining_capacity)){
                                if(remaining_capacity <= 100*1024*1024){
                                    let archive_canister = await _deploy_archive_canister();
                                    last_archive := archive_canister;
                                    is_deployed := true;
                                    archive_data := {
                                        archive_data with
                                        canister = archive_canister;
                                        start = _append_array[0].index;
                                    };
                                }else{
                                    archive_data := last_archive_data;
                                }
                        };
                        case(#err(err)){
                            _last_error_message := "Get remaining capacity error: " # debug_show(err) #", at " #Int.toText(Time.now());
                            Debug.print(_last_error_message);
                            return;
                        };
                    };
                }else{
                    //deploy new archive
                    let archive_canister = await _deploy_archive_canister();
                    last_archive := archive_canister;
                    is_deployed := true;
                    archive_data := {
                        archive_data with
                        canister = archive_canister;
                        start = _append_array[0].index;
                    };
                };
                switch(await last_archive.append_news(_append_array)){
                    case(#ok(_)){
                        if(is_deployed){
                            //append new archive to archives
                            archive_data := {
                                archive_data with
                                stored_news = _append_array.size();
                                end = _append_array[Nat.sub(_append_array.size(), 1)].index;
                            };
                            _archives := Array.append(_archives, [archive_data]);
                        }else{
                            //update last archive
                            archive_data := {
                                archive_data with
                                stored_news = archive_data.stored_news + _append_array.size();
                                end = _append_array[Nat.sub(_append_array.size(), 1)].index;
                            };
                            if(_archives.size() > 1){
                                let new_archives = Array.append(Array.subArray(_archives, 0, Nat.sub(_archives.size(), 1)), [archive_data]);
                                _archives := new_archives;
                            }else{
                                _archives := [archive_data];
                            };
                        };
                    };
                    case(#err(err)){
                        _last_error_message := "Append news to archive error: " # debug_show(err) #", at " #Int.toText(Time.now());
                        Debug.print(_last_error_message);
                    };
                };
            };
        }catch(err){
            _last_error_message := "Save to archive throw exception: " # debug_show(Error.message(err)) #", at " #Int.toText(Time.now());
            Debug.print(_last_error_message);
        };
        _task_status := false;
    };

    private func _deploy_archive_canister() : async Types.ArchiveInterface {
        let cycles_balance = Cycles.balance();
        if (cycles_balance < DEPLOY_CANISTER_CYCLE) {
            throw Error.reject("Cycle: Insufficient cycles balance");
        };
        Cycles.add<system>(DEPLOY_CANISTER_CYCLE);
        let archive_canister = await Archive.Archive();
        let archive_canister_id = Principal.fromActor(archive_canister);
        return actor(Principal.toText(archive_canister_id));
    };

    system func preupgrade() {
        _news_array := Buffer.toArray(_news_buffer);
    };

    system func postupgrade() {
        _news_buffer := Buffer.fromArray<Types.News>(_news_array);
    };

    ignore Timer.recurringTimer<system>(#seconds(60 * 10), _save_to_archive);

}

