import Foundation
import Testing
@testable import IndexaCore

struct TailscaleTests {
    @Test func privateServeRemovesOnlyItsPublicExposure() throws {
        let original:[String:Any] = ["TCP":["8443":["HTTPS":true]],"AllowFunnel":["other.ts.net:8443":true]]
        let config=try TailscaleClient.serveConfiguration(current:original,host:"indexa.ts.net",port:18761,enabled:true)
        #expect((config["AllowFunnel"] as? [String:Bool])?["indexa.ts.net:443"] != true)
        #expect((config["AllowFunnel"] as? [String:Bool])?["other.ts.net:8443"] == true)
        var publicConfig=config
        publicConfig["AllowFunnel"]=["indexa.ts.net:443":true,"other.ts.net:8443":true]
        let privateConfig=try TailscaleClient.serveConfiguration(current:publicConfig,host:"indexa.ts.net",port:18761,enabled:true)
        #expect((privateConfig["AllowFunnel"] as? [String:Bool])?["indexa.ts.net:443"] != true)
        #expect((privateConfig["TCP"] as? [String:Any])?["8443"] != nil)
    }
    @Test func refusesToOverwriteOtherServices() throws {
        let other:[String:Any] = ["TCP":["443":["HTTPS":true]],"Web":["other.ts.net:443":["Handlers":["/":["Proxy":"http://127.0.0.1:9999"]]]]]
        #expect(throws:(any Error).self) { try TailscaleClient.serveConfiguration(current:other,host:"indexa.ts.net",port:18761,enabled:true) }
        let config=try TailscaleClient.serveConfiguration(current:["TCP":["8443":["HTTPS":true]]],host:"indexa.ts.net",port:18761,enabled:true)
        #expect((config["AllowFunnel"] as? [String:Bool])?["indexa.ts.net:443"] != true)
        #expect((config["TCP"] as? [String:Any])?["8443"] != nil)
        let off=try TailscaleClient.serveConfiguration(current:config,host:"indexa.ts.net",port:18761,enabled:false)
        #expect((off["TCP"] as? [String:Any])?["8443"] != nil)
        #expect((off["TCP"] as? [String:Any])?["443"] == nil)
    }
}
