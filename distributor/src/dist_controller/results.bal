import ballerina/http;
import ballerina/io;
import ballerina/lang.'int;
import ballerina/log;
import ballerina/runtime;
import ballerina/time;

http:Client? secondaryDistributor = ();

# Service for results tabulation to publish results to. We assume that results tabulation will deliver
# a result in two separate messages - one with the json result data and another with an image of the
# signed result document with both messages referring to the same message code which must be unique
# per result. We also assume that the results data will come first (as that's what creates the row)
# and then the image.
# 
# The two message approach is done only to make it easier for the publisher - the approach of using 
# a multipart/x (x = alternative or related) would've been better. 
# 
# Both will be saved for resilience and later access for subscribers who want it.

@http:ServiceConfig {
    basePath: "/result",
    auth: {
        scopes: ["publisher"]
    }
}
service receiveResults on resultsListener {

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/notification/{electionCode}/{resultType}/{resultCode}"
    }
    resource function receiveNotification(http:Caller caller, http:Request req, string electionCode, string resultType,
                                          string resultCode) returns error? {
        log:printInfo("Result notification received for " + electionCode +  "/" + resultType + "/" + resultCode);

        var levelQueryParam = req.getQueryParamValue("level");
        if levelQueryParam is () {
            return caller->badRequest("Missing required 'level' query param for notification");
        }

        string level = <string> levelQueryParam;
        string? ed_name = req.getQueryParamValue("ed_name");
        string? pd_name = req.getQueryParamValue("pd_name");
        string message = getAwaitResultsMessage(electionCode, "/" + resultType, resultCode, level, ed_name, pd_name);

        _ = start triggerAwaitNotification(<@untainted> message);        

         if validSmsClient {
             _ = start sendSMS(<@untainted> message, <@untainted> (electionCode + "/" + resultType + "/" + resultCode));
         }

        // respond accepted
        return caller->accepted();
    }

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/data/{electionCode}/{resultType}/{resultCode}",
        body: "jsonResult"
    }
    resource function receiveData(http:Caller caller, http:Request req, string electionCode, string resultType,
                                  string resultCode, json jsonResult) returns error? {

        // payload is supposed to be a json object - its ok to get upset if not
        map<json> jsonobj = check trap <map<json>> jsonResult;

        // check and convert numbers to ints if they're strings
        cleanupJsonFunc(jsonobj);

        // save everything in a convenient way
        Result result = <@untainted> {
            sequenceNo: -1, // wil be updated with DB sequence # upon storage
            election: electionCode,
            'type: resultType,
            code: resultCode,
            jsonResult: <map<json>> jsonResult,
            imageMediaType: (),
            imageData: ()
        };
        log:printInfo("Result data received for " + electionCode +  "/" + resultType + "/" + resultCode);

        // store the result in the DB against the resultCode and assign it a sequence #
        CumulativeResult? resCumResult = check saveResult(result);
    
        _ = start triggerResultDelivery(constructResultData(result));

        if !(resCumResult is ()) {
            check sendIncrementalResultFunc(resCumResult, electionCode, resultType, resultCode, result);
        }

        // respond accepted
        return caller->accepted();
     }

    @http:ResourceConfig {
        methods: ["POST"],
        path: "/image/{electionCode}/{resultType}/{resultCode}",
        body: "imageData"
    }
    resource function receiveImage(http:Caller caller, http:Request req, string electionCode, string resultType, 
                                   string resultCode, byte[] imageData) returns error? {
        log:printInfo("Result image received for " + electionCode +  "/" + resultType + "/" + resultCode);

        string mediaType = req.getContentType();

        // store the image in the DB against the resultCode and retrieve the relevant result
        Result? res = check saveImage(<@untainted> electionCode, <@untainted> resultType, <@untainted> resultCode, 
                                      <@untainted> mediaType, <@untainted> imageData);

        if (res is Result) {
            int sequenceNo = <int> res.sequenceNo;

            map<json> update = {
                election_code: electionCode,
                sequence_number: io:sprintf("%04d", sequenceNo),
                'type: res.'type,
                level: res.jsonResult.level.toString(),
                pd_code: res.jsonResult.pd_code.toString(),
                ed_code: res.jsonResult.ed_code.toString(),
                pd_name: res.jsonResult.pd_name.toString(),
                ed_name: res.jsonResult.ed_name.toString()
            };
            _ = start triggerImageDelivery(<@untainted> update);
        }

        // respond accepted
        return caller->accepted();
    }

    resource function reset(http:Caller caller, http:Request req) returns error? {
        log:printInfo("Resetting all results ..");
        check resetResults();
        return caller->accepted();
    }
}

function triggerAwaitNotification(string message) {
    http:Client cl = <http:Client> secondaryDistributor;
    var res = cl->post("/await", message);
    if res is error {
        log:printError("Error triggering await notification for " + cl.url, res);
    }
}

function triggerResultDelivery(json data) {
    http:Client cl = <http:Client> secondaryDistributor;
    var res = cl->post("/result", data);
    if res is error {
        log:printError("Error triggering result delivery for " + cl.url, res);
    }
}

function triggerImageDelivery(json image) {
    http:Client cl = <http:Client> secondaryDistributor;
    var res = cl->post("/image", image);
    if res is error {
        log:printError("Error triggering image delivery for " + cl.url, res);
    }
}

function constructResultData(Result result, string? electionCode = (), string? resultCode = ()) returns json {
    map<json> jsonResult = result.jsonResult;

    if jsonResult.level == LEVEL_N && !(jsonResult.by_party is error) {
        jsonResult["by_party"] = byPartySortFunction(<json[]> jsonResult.by_party, result.'type);
    }

    // push it out with the election code and the json result as the message
    return {
        election_code : result.election,
        result : jsonResult
    };
}

function cleanupPresidentialJson(map<json> jin) {
    json[] by_party = <json[]> jin.by_party;
    foreach json j2 in by_party {
        map<json> j = <map<json>> j2;
        if j.votes is string {
            j["vote_count"] = (j.vote_count == "") ? 0 : <int>'int:fromString(<string>j.vote_count);
        }
        if j.votes1st is string {
            j["votes1st"] = (j.votes1st == "") ? 0 : <int>'int:fromString(<string>j.votes1st);
        }
        if j.votes2nd is string {
            j["votes2nd"] = (j.votes2nd == "") ? 0 : <int>'int:fromString(<string>j.votes2nd);
        }
        if j.votes3rd is string {
            j["votes3rd"] = (j.votes3rd == "") ? 0 : <int>'int:fromString(<string>j.votes3rd);
        }
    }
    cleanUpSummaryJson(<map<json>>jin.summary);
}

function cleanupParliamentaryJson(map<json> jin) {
    if (jin.hasKey("by_party")) {
        json[] by_party = <json[]> jin.by_party;
        foreach json j2 in by_party {
            map<json> j = <map<json>> j2;
            if j.votes is string {
                j["vote_count"] = (j.vote_count == "") ? 0 : <int>'int:fromString(<string>j.vote_count);
            }
            if j.seat_count is string {
                j["seat_count"] = (j.seat_count == "") ? 0 : <int>'int:fromString(<string>j.seat_count);
            }
            if j.national_list_seat_count is string {
                j["national_list_seat_count"] = (j.national_list_seat_count == "") ? 0 :
                                                    <int>'int:fromString(<string>j.national_list_seat_count);
            }
        }
    }

    if !(jin.hasKey("summary")) {
        return;
    }

    cleanUpSummaryJson(<map<json>>jin.summary);
}

function cleanUpSummaryJson(map<json> js) {
    if js.valid is string {
        js["valid"] = (js.valid == "") ? 0 : <int>'int:fromString(<string>js.valid);
    }
    if js.rejected is string {
        js["rejected"] = (js.rejected == "") ? 0 : <int>'int:fromString(<string>js.rejected);
    }
    if js.polled is string {
        js["polled"] = (js.polled == "") ? 0 : <int>'int:fromString(<string>js.polled);
    }
    if js.electors is string {
        js["electors"] = (js.electors == "") ? 0 : <int>'int:fromString(<string>js.electors);
    }
}

function sendPresidentialIncrementalResult(CumulativeResult resCumResult, string electionCode, string resultType,
                                           string resultCode, Result result) returns error? {
    // send a cumulative result with the current running totals
    log:printInfo("Publishing cumulative result with " + electionCode +  "/" + resultType + "/" + resultCode);

    PresidentialCumulativeVotesResult presidentialCumResult = <PresidentialCumulativeVotesResult> resCumResult;

    map<json> cumJsonResult = {
        'type: resultType,
        timestamp: check time:format(time:currentTime(), "yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        level: "NATIONAL-INCREMENTAL",
        by_party: check json.constructFrom(presidentialCumResult.by_party),
        summary: check json.constructFrom(presidentialCumResult.summary)
    };
    Result cumResult = <@untainted> {
        sequenceNo: -1, // wil be updated with DB sequence # upon storage
        election: result.election,
        'type: result.'type,
        code: result.code,
        jsonResult: cumJsonResult,
        imageMediaType: (),
        imageData: ()
    };

    // store the result in the DB against the resultCode and assign it a sequence #
    // Ignore the non-error return value, since it would be `()`, when saving an incremental result
    _ = check saveResult(cumResult);

    // publish the received cumulative result
    _ = start triggerResultDelivery(constructResultData(cumResult));
}

function sendParliamentaryIncrementalResult(CumulativeResult resCumResult, string electionCode, string resultType,
                                            string resultCode, Result result) returns error? {
    if resCumResult is ParliamentaryCumulativeVotesResult {
        return sendParliamentaryIncrementalVotesResult(resCumResult, electionCode, RE_VI, resultCode, result);
    }

    return sendParliamentaryIncrementalSeatsResult(resCumResult, electionCode, RN_SI, resultCode, result);
}

function sendParliamentaryIncrementalVotesResult(CumulativeResult resCumResult, string electionCode, string resultType,
                                                 string resultCode, Result result) returns error? {
    log:printInfo("Publishing cumulative result with " + electionCode +  "/" + resultType + "/" + resultCode);

    ParliamentaryCumulativeVotesResult parliamentaryCumResult = <ParliamentaryCumulativeVotesResult> resCumResult;

    map<json> cumJsonResult = {
        'type: resultType,
        timestamp: check time:format(time:currentTime(), "yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        level: "ELECTORAL-DISTRICT",
        ed_code: <string> result.jsonResult.ed_code,
        ed_name: <string> result.jsonResult.ed_name,
        by_party: check json.constructFrom(parliamentaryCumResult.by_party),
        summary: check json.constructFrom(parliamentaryCumResult.summary)
    };
    Result cumResult = <@untainted> {
        sequenceNo: -1, // wil be updated with DB sequence # upon storage
        election: result.election,
        'type: resultType,
        code: result.code,
        jsonResult: cumJsonResult,
        imageMediaType: (),
        imageData: ()
    };

    // store the result in the DB against the resultCode and assign it a sequence #
    // Ignore the non-error return value, since it would be `()`, when saving an incremental result
    _ = check saveResult(cumResult);

    // add small delay between original result and incremental result publish
    runtime:sleep(1000);
    // publish the received cumulative result
    _ = start triggerResultDelivery(constructResultData(cumResult));
}

function sendParliamentaryIncrementalSeatsResult(CumulativeResult resCumResult, string electionCode, string resultType,
                                                 string resultCode, Result result) returns error? {
    log:printInfo("Publishing cumulative result with " + electionCode +  "/" + resultType + "/" + resultCode);

    ParliamentaryCumulativeSeatsResult parliamentaryCumResult = <ParliamentaryCumulativeSeatsResult> resCumResult;

    map<json> cumJsonResult = {
        'type: resultType,
        timestamp: check time:format(time:currentTime(), "yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        level: "NATIONAL",
        by_party: check json.constructFrom(parliamentaryCumResult.by_party)
    };
    Result cumResult = <@untainted> {
        sequenceNo: -1, // wil be updated with DB sequence # upon storage
        election: result.election,
        'type: resultType,
        code: result.code,
        jsonResult: cumJsonResult,
        imageMediaType: (),
        imageData: ()
    };

    // store the result in the DB against the resultCode and assign it a sequence #
    // Ignore the non-error return value, since it would be `()`, when saving an incremental result
    _ = check saveResult(cumResult);

    // add small delay between original result and incremental result publish
    runtime:sleep(1000);
    // publish the received cumulative result
    _ = start triggerResultDelivery(constructResultData(cumResult));
}
