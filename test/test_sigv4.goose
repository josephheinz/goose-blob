// SigV4 against AWS's published vectors: the generic test suite (below, generated from its files) and the S3
// examples from the S3 API reference (header auth for GET with Range, PUT, ?lifecycle, list; the presigned GET).
// No network.   test/run.sh test_sigv4
import blob from "..";
import blob.sigv4;
import blob.s3;
import gweb from "../../goose-web";
import net from "../../goose-net";
import std;

var failed = 0;
var total = 0;
fn check(name: const u8[:], ok: bool) { total += 1; if !ok { write_stderr(str("FAIL ", name, "\n")); failed += 1; } }
fn check_eq(name: const u8[:], got: const u8[:], want: const u8[:]) {
    total += 1;
    if got != want { write_stderr(str("FAIL ", name, "\n  got:  ", got, "\n  want: ", want, "\n")); failed += 1; }
}

// Generated from AWS's SigV4 test suite (aws-sig-v4-test-suite, as kept in botocore tests/unit/auth/aws4_testsuite).
// Credentials AKIDEXAMPLE / wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY, us-east-1, service "service", 20150830T123600Z.
struct Vector { name: const u8[:], method: const u8[:], path: const u8[:], query: const u8[:], headers: const u8[:], body: const u8[:], creq: const u8[:], sts: const u8[:], authz: const u8[:] }
let VECTORS = [
    Vector { name: "get-header-key-duplicate", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nMy-Header1:value2\nMy-Header1:value2\nMy-Header1:value1\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nmy-header1:value2,value2,value1\nx-amz-date:20150830T123600Z\n\nhost;my-header1;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\ndc7f04a3abfde8d472b0ab1a418b741b7c67174dad1551b4117b15527fbe966c", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;x-amz-date, Signature=c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea" },
    Vector { name: "get-header-value-order", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nMy-Header1:value4\nMy-Header1:value1\nMy-Header1:value3\nMy-Header1:value2\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nmy-header1:value4,value1,value3,value2\nx-amz-date:20150830T123600Z\n\nhost;my-header1;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n31ce73cd3f3d9f66977ad3dd957dc47af14df92fcd8509f59b349e9137c58b86", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;x-amz-date, Signature=08c7e5a9acfcfeb3ab6b2185e75ce8b1deb5e634ec47601a50643f830c755c01" },
    Vector { name: "get-header-value-trim", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nMy-Header1: value1\nMy-Header2: \"a   b   c\"\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nmy-header1:value1\nmy-header2:\"a b c\"\nx-amz-date:20150830T123600Z\n\nhost;my-header1;my-header2;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\na726db9b0df21c14f559d0a978e563112acb1b9e05476f0a6a1c7d68f28605c7", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;my-header2;x-amz-date, Signature=acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736" },
    Vector { name: "get-unreserved", method: "GET", path: "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n6a968768eefaa713e2a6b16b589a8ea192661f098f37349f4e2c0082757446f9", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f" },
    Vector { name: "get-utf8", method: "GET", path: "/ሴ", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/%E1%88%B4\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n2a0a97d02205e45ce2e994789806b19270cfbbb0921b278ccf58f5249ac42102", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85" },
    Vector { name: "get-vanilla", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31" },
    Vector { name: "get-vanilla-empty-query-key", method: "GET", path: "/", query: "Param1=value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\nParam1=value1\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n1e24db194ed7d0eec2de28d7369675a243488e08526e8c1c73571282f7c517ab", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb" },
    Vector { name: "get-vanilla-query", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31" },
    Vector { name: "get-vanilla-query-order-encoded", method: "GET", path: "/", query: "Param-3=Value3&Param=Value2&%E1%88%B4=Value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n\n", body: "",
             creq: "GET\n/\n%E1%88%B4=Value1&Param=Value2&Param-3=Value3\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n868294f5c38bd141c4972a373a76654f1418a8e4fc18b2e7903ae45e8ae0ec71", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=371d3713e185cc334048618a97f809c9ffe339c62934c032af5a0e595648fcac" },
    Vector { name: "get-vanilla-query-order-key", method: "GET", path: "/", query: "Param1=value2&Param1=Value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\nParam1=Value1&Param1=value2\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n704b4cef673542d84cdff252633f065e8daeba5f168b77116f8b1bcaf3d38f89", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=eedbc4e291e521cf13422ffca22be7d2eb8146eecf653089df300a15b2382bd1" },
    Vector { name: "get-vanilla-query-order-key-case", method: "GET", path: "/", query: "Param2=value2&Param1=value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\nParam1=value1&Param2=value2\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n816cd5b414d056048ba4f7c5386d6e0533120fb1fcfa93762cf0fc39e2cf19e0", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500" },
    Vector { name: "get-vanilla-query-order-value", method: "GET", path: "/", query: "Param1=value2&Param1=value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\nParam1=value1&Param1=value2\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nc968629d70850097a2d8781c9bf7edcb988b04cac14cca9be4acc3595f884606", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5772eed61e12b33fae39ee5e7012498b51d56abc0abb7c60486157bd471c4694" },
    Vector { name: "get-vanilla-query-unreserved", method: "GET", path: "/", query: "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz=-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz=-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nc30d4703d9f799439be92736156d47ccfb2d879ddf56f5befa6d1d6aab979177", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197" },
    Vector { name: "get-vanilla-utf8-query", method: "GET", path: "/", query: "ሴ=bar", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "GET\n/\n%E1%88%B4=bar\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\neb30c5bed55734080471a834cc727ae56beb50e5f39d1bff6d0d38cb192a7073", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04" },
    Vector { name: "get-vanilla-with-session-token", method: "GET", path: "/", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\nX-Amz-Security-Token:6e86291e8372ff2a2260956d9b8aae1d763fbf315fa00fa31553b73ebf194267\n", body: "",
             creq: "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\nx-amz-security-token:6e86291e8372ff2a2260956d9b8aae1d763fbf315fa00fa31553b73ebf194267\n\nhost;x-amz-date;x-amz-security-token\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n067b36aa60031588cea4a4cde1f21215227a047690c72247f1d70b32fbbfad2b", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=07ec1639c89043aa0e3e2de82b96708f198cceab042d4a97044c66dd9f74e7f8" },
    Vector { name: "post-header-key-case", method: "POST", path: "/", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n553f88c9e4d10fc9e109e2aeb65f030801b70c2f6468faca261d401ae622fc87", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b" },
    Vector { name: "post-header-key-sort", method: "POST", path: "/", query: "", headers: "Host:example.amazonaws.com\nMy-Header1:value1\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\n\nhost:example.amazonaws.com\nmy-header1:value1\nx-amz-date:20150830T123600Z\n\nhost;my-header1;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n9368318c2967cf6de74404b30c65a91e8f6253e0a8659d6d5319f1a812f87d65", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;x-amz-date, Signature=c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c" },
    Vector { name: "post-header-value-case", method: "POST", path: "/", query: "", headers: "Host:example.amazonaws.com\nMy-Header1:VALUE1\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\n\nhost:example.amazonaws.com\nmy-header1:VALUE1\nx-amz-date:20150830T123600Z\n\nhost;my-header1;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nd51ced243e649e3de6ef63afbbdcbca03131a21a7103a1583706a64618606a93", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d" },
    Vector { name: "post-vanilla", method: "POST", path: "/", query: "", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n553f88c9e4d10fc9e109e2aeb65f030801b70c2f6468faca261d401ae622fc87", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b" },
    Vector { name: "post-vanilla-empty-query-value", method: "POST", path: "/", query: "Param1=value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\nParam1=value1\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n9d659678c1756bb3113e2ce898845a0a79dbbc57b740555917687f1b3340fbbd", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11" },
    Vector { name: "post-vanilla-query", method: "POST", path: "/", query: "Param1=value1", headers: "Host:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "",
             creq: "POST\n/\nParam1=value1\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n9d659678c1756bb3113e2ce898845a0a79dbbc57b740555917687f1b3340fbbd", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11" },
    Vector { name: "post-x-www-form-urlencoded", method: "POST", path: "/", query: "", headers: "Content-Type:application/x-www-form-urlencoded\nHost:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "Param1=value1",
             creq: "POST\n/\n\ncontent-type:application/x-www-form-urlencoded\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\ncontent-type;host;x-amz-date\n9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n42a5e5bb34198acb3e84da4f085bb7927f2bc277ca766e6d19c73c2154021281", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a" },
    Vector { name: "post-x-www-form-urlencoded-parameters", method: "POST", path: "/", query: "", headers: "Content-Type:application/x-www-form-urlencoded; charset=utf8\nHost:example.amazonaws.com\nX-Amz-Date:20150830T123600Z\n", body: "Param1=value1",
             creq: "POST\n/\n\ncontent-type:application/x-www-form-urlencoded; charset=utf8\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\ncontent-type;host;x-amz-date\n9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e", sts: "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n2e1cf7ed91881a30569e46552437e4156c823447bf1781b921b5d486c568dd1c", authz: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=1a72ec8f64bd914b0e42e42607c7fbce7fb2c7465f63e3092b3b0d39fa77a6fe" },
];

let SUITE_ID = "AKIDEXAMPLE";
let SUITE_SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
let SUITE_DATE = "20150830T123600Z";

fn test_suite() {
    for v in VECTORS {
        var path: u8[>..] = [];
        blob::uri_encode(path, v.path, true);
        var payload: u8[>..] = [];
        blob::sha256_hex(payload, v.body);
        var creq: u8[>..] = [];
        var signed: u8[>..] = [];
        check(str(v.name, " parses"), blob::canonical_request(creq, signed, v.method, path, v.query, v.headers, payload));
        check_eq(str(v.name, " canonical request"), creq, v.creq);
        var scope: u8[>..] = [];
        blob::credential_scope(scope, SUITE_DATE, "us-east-1", "service");
        var sts: u8[>..] = [];
        blob::string_to_sign(sts, SUITE_DATE, scope, creq);
        check_eq(str(v.name, " string to sign"), sts, v.sts);
        var authz: u8[>..] = [];
        check(str(v.name, " signs"), blob::authorization(authz, SUITE_ID, SUITE_SECRET, SUITE_DATE, "us-east-1", "service",
                                                          v.method, path, v.query, v.headers, payload));
        check_eq(str(v.name, " authorization"), authz, v.authz);
    }
}

// The S3 API reference examples: examplebucket, AKIAIOSFODNN7EXAMPLE, 2013-05-24 00:00:00 UTC.
let S3_ID = "AKIAIOSFODNN7EXAMPLE";
let S3_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
let S3_DATE = "20130524T000000Z";
let S3_TIME = 1369353600;
let EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

fn sig_of(authz: const u8[:]) -> const u8[:] {
    let at = find(authz, "Signature=");
    if at < 0 { return ""; }
    return authz[at + 10..];
}

fn test_s3_examples() {
    var a: u8[>..] = [];
    check("GET object", blob::authorization(a, S3_ID, S3_SECRET, S3_DATE, "us-east-1", "s3", "GET", "/test.txt", "",
        str("Host: examplebucket.s3.amazonaws.com\nRange: bytes=0-9\nx-amz-content-sha256: ", EMPTY, "\nx-amz-date: ", S3_DATE, "\n"), EMPTY));
    check_eq("GET object authorization", a, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");

    var body_hash: u8[>..] = [];
    blob::sha256_hex(body_hash, "Welcome to Amazon S3.");
    check_eq("PUT payload hash", body_hash, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072");
    var p: u8[>..] = [];
    var path: u8[>..] = [];
    blob::uri_encode(path, "/test$file.text", true);
    check_eq("PUT path", path, "/test%24file.text");
    blob::authorization(p, S3_ID, S3_SECRET, S3_DATE, "us-east-1", "s3", "PUT", path, "",
        str("Host: examplebucket.s3.amazonaws.com\nDate: Fri, 24 May 2013 00:00:00 GMT\nx-amz-date: ", S3_DATE,
            "\nx-amz-storage-class: REDUCED_REDUNDANCY\nx-amz-content-sha256: ", body_hash, "\n"), body_hash);
    check_eq("PUT object signature", sig_of(p), "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");

    var l: u8[>..] = [];
    blob::authorization(l, S3_ID, S3_SECRET, S3_DATE, "us-east-1", "s3", "GET", "/", "lifecycle",
        str("Host: examplebucket.s3.amazonaws.com\nx-amz-date: ", S3_DATE, "\nx-amz-content-sha256: ", EMPTY, "\n"), EMPTY);
    check_eq("GET lifecycle signature", sig_of(l), "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543");

    var g: u8[>..] = [];
    blob::authorization(g, S3_ID, S3_SECRET, S3_DATE, "us-east-1", "s3", "GET", "/", "max-keys=2&prefix=J",
        str("Host: examplebucket.s3.amazonaws.com\nx-amz-date: ", S3_DATE, "\nx-amz-content-sha256: ", EMPTY, "\n"), EMPTY);
    check_eq("list objects signature", sig_of(g), "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7");

    var q: u8[>..] = [];
    check("presign", blob::presign_query(q, S3_ID, S3_SECRET, "", S3_DATE, "us-east-1", "s3", 86400, "GET", "/test.txt", "",
                                         "Host: examplebucket.s3.amazonaws.com\n"));
    check_eq("presigned query", q, "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404");
}

// The same examples through a store: virtual-host style on the global host the examples use, keys given to open.
fn test_store_signing() {
    let s, ok = blob::open("s3://examplebucket?endpoint=https://s3.amazonaws.com&style=virtual&region=us-east-1", "", S3_ID, S3_SECRET, "");
    check("open example store", ok && !s.path_style && s.host == "s3.amazonaws.com");
    var u: u8[>..] = [];
    check("store presign", blob::_s3_presign_get(s, "test.txt", 86400, S3_TIME, u));
    check_eq("store presigned URL", u, "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404");
    var hs: u8[>..] = [];
    check("store sign", blob::_s3_sign(hs, s, "GET", "/test.txt", "", "Range: bytes=0-9\n", EMPTY, S3_TIME));
    check_eq("store signed headers", hs, str("Host: examplebucket.s3.amazonaws.com\nRange: bytes=0-9\nx-amz-content-sha256: ", EMPTY,
        "\nx-amz-date: 20130524T000000Z\nAuthorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41\n"));

    // ttl limits; disk stores do not presign
    var x: u8[>..] = [];
    check("ttl 0 refused", !blob::presign_get(s, "a", 0, x) && x.len == 0);
    check("ttl over 7 days refused", !blob::presign_get(s, "a", 604801, x));
    check("ttl 7 days", blob::presign_get(s, "a", 604800, x) && find(x, "X-Amz-Expires=604800") >= 0);
    check("presign bad key", !blob::presign_get(s, "../a", 60, x));

    // a session token is signed into a presigned URL
    let t, tok = blob::open("s3://examplebucket/pre/fix?endpoint=https://minio.example.com:9000&region=auto", "", S3_ID, S3_SECRET, "tok/en+=");
    check("open with token", tok && t.path_style && t.prefix == "pre/fix/" && t.region == "auto");
    var tu: u8[>..] = [];
    check("presign with token", blob::_s3_presign_get(t, "k.txt", 60, S3_TIME, tu));
    check("token in URL", find(tu, "&X-Amz-Security-Token=tok%2Fen%2B%3D&") >= 0);
    check("path-style URL", starts_with(tu, "https://minio.example.com:9000/examplebucket/pre/fix/k.txt?X-Amz-Algorithm="));
    check("region auto in scope", find(tu, "%2Fauto%2Fs3%2Faws4_request") >= 0);

    // presigned PUT: the headers to send come back, and are signed
    var pu: u8[>..] = [];
    var ph: u8[>..] = [];
    let o = blob::PutOptions { content_type: "image/png", immutable: true, .. };
    check("presign put", blob::_s3_presign_put(t, "a.png", o, 1234, 600, S3_TIME, pu, ph));
    check_eq("presign put headers", ph, "Content-Length: 1234\nContent-Type: image/png\nCache-Control: public, max-age=31536000, immutable\n");
    check("presign put signs them", find(pu, "X-Amz-SignedHeaders=cache-control%3Bcontent-length%3Bcontent-type%3Bhost&") >= 0);
}

fn test_open_errors() {
    let a, oka = blob::open("s3://Bad_Bucket", "", "id", "secret", "");
    check("bad bucket", !oka && find(blob::last_error(), "bucket") >= 0);
    let b, okb = blob::open("s3://bucket", "", "", "", "");
    check("no keys", !okb && find(blob::last_error(), "credentials") >= 0);
    let c, okc = blob::open("s3://bucket?endpoint=http://s3.example.com", "", "id", "secret", "");
    check("plain http refused off localhost", !okc && find(blob::last_error(), "plain_http") >= 0);
    let d, okd = blob::open("s3://bucket?endpoint=http://s3.example.com&plain_http=1", "", "id", "secret", "");
    check("plain http when asked", okd && d.scheme == "http");
    let e, oke = blob::open("s3://bucket?endpoint=http://127.0.0.1:9000", "", "id", "secret", "");
    check("http on loopback", oke && e.scheme == "http" && e.host == "127.0.0.1:9000");
    let f, okf = blob::open("s3://bucket?endpoint=https://h.example.com/path", "", "id", "secret", "");
    check("endpoint with a path refused", !okf);
    let g, okg = blob::open("s3://bucket?endpont=x", "", "id", "secret", "");
    check("unknown parameter", !okg && find(blob::last_error(), "endpont") >= 0);
    let h, okh = blob::open("s3://bucket/../x", "", "id", "secret", "");
    check("bad prefix", !okh);
    let i, oki = blob::open("s3://bucket?endpoint=https://r2.example.com&style=virtual", "https://cdn.example.com", "id", "secret", "");
    check("virtual style forced", oki && !i.path_style && i.public_base == "https://cdn.example.com/");
    let j, okj = blob::open("ftp://x", "", "", "", "");
    check("unknown scheme", !okj);
    let k, okk = blob::open("s3://bucket", "", "id", "secret", "");
    check("AWS default host", okk && k.host == "s3.us-east-1.amazonaws.com" && !k.path_style && k.region == "us-east-1");
    var u: u8[>..] = [];
    check("private s3 store has no url", !blob::url(k, "a", u));
    check("public url", blob::url(i, "c/x.png", u) && u == "https://cdn.example.com/c/x.png");
    let sub, oksub = blob::sub(i, "c/blog");
    var su: u8[>..] = [];
    check("sub store", oksub && sub.prefix == "c/blog/" && blob::url(sub, "m/a.png", su) && su == "https://cdn.example.com/c/blog/m/a.png");
}

fn test_helpers() {
    var e: u8[>..] = [];
    blob::uri_encode(e, "a b/c~d*", false);
    check_eq("uri_encode", e, "a%20b%2Fc~d%2A");
    var q: u8[>..] = [];
    blob::canonical_query(q, "b=2&a=&a=1&c");
    check_eq("canonical query", q, "a=&a=1&b=2&c=");
    var d: u8[>..] = [];
    blob::amz_date(d, 1440938160);
    check_eq("amz date", d, "20150830T123600Z");
    var d0: u8[>..] = [];
    blob::amz_date(d0, 951782400);
    check_eq("leap day", d0, "20000229T000000Z");
    let t, ok = blob::parse_iso_time("2013-05-24T00:00:00.000Z");
    check("iso time", ok && t == S3_TIME);
    let t2, ok2 = blob::parse_http_time("Fri, 24 May 2013 00:00:00 GMT");
    check("http time", ok2 && t2 == S3_TIME);
    let t3, ok3 = blob::parse_http_time("Fri, 24 Mxy 2013 00:00:00 GMT");
    check("bad http time", !ok3);
    var c: u8[>..] = [];
    var sg: u8[>..] = [];
    check("bad header refused", !blob::canonical_request(c, sg, "GET", "/", "", "no colon here\n", EMPTY));
}

fn main() {
    test_suite();
    test_s3_examples();
    test_store_signing();
    test_open_errors();
    test_helpers();
    print("test_sigv4: ", total - failed, " of ", total, " checks passed");
    if failed > 0 { exit(1); }
}
