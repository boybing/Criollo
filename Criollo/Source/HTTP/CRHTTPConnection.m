//
//  CRHTTPConnection.m
//  Criollo
//
//  Created by Cătălin Stan on 10/25/15.
//  Copyright © 2015 Cătălin Stan. All rights reserved.
//

#import "CRHTTPConnection.h"
#import "CRConnection_Internal.h"
#import "GCDAsyncSocket.h"
#import "CRApplication.h"
#import "CRHTTPServer.h"
#import "CRServer_Internal.h"
#import "CRHTTPServerConfiguration.h"
#import "CRMessage.h"
#import "CRMessage_Internal.h"
#import "CRRequest.h"
#import "CRRequest_Internal.h"
#import "CRResponse_Internal.h"
#import "CRHTTPResponse.h"

@interface CRHTTPConnection () {
    NSUInteger requestBodyLength;
    NSUInteger requestBodyReceivedBytesLength;
    BOOL didPerformInitialRead;
}

@end

@implementation CRHTTPConnection

#pragma mark - Data

- (void)startReading {
    [super startReading];

    requestBodyLength = 0;
    requestBodyReceivedBytesLength = 0;

    CRHTTPServerConfiguration* config = (CRHTTPServerConfiguration*)self.server.configuration;

    // Read the request headers
    NSUInteger timeout = didPerformInitialRead ? config.CRConnectionKeepAliveTimeout : config.CRConnectionReadTimeout + config.CRHTTPConnectionReadHeaderTimeout;
    [self.socket readDataToData:[CRConnection CRLFCRLFData] withTimeout:timeout maxLength:config.CRRequestMaxHeaderLength tag:CRHTTPConnectionSocketTagBeginReadingRequest];
}

- (void)didReceiveCompleteRequestHeaders {
    // Create ENV from HTTP headers
    NSMutableDictionary* env = [NSMutableDictionary dictionary];
    [self.currentRequest.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSString * _Nonnull obj, BOOL * _Nonnull stop) {
        NSString* headerName = [@"HTTP_" stringByAppendingString:[key.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@"_"]];
        [env setObject:obj forKey:headerName];
    }];

    if ( env[@"HTTP_CONTENT_LENGTH"] ) {
        env[@"CONTENT_LENGTH"] = env[@"HTTP_CONTENT_LENGTH"];
    }
    if ( env[@"HTTP_CONTENT_TYPE"] ) {
        env[@"CONTENT_TYPE"] = env[@"HTTP_CONTENT_TYPE"];
    }

    if ( env[@"HTTP_HOST"]) {
        env[@"SERVER_NAME"] = env[@"HTTP_HOST"];
    }
//    env[@"SERVER_SOFTWARE"] = @"";
    env[@"REQUEST_METHOD"] = NSStringFromCRHTTPMethod(self.currentRequest.method);
    env[@"SERVER_PROTOCOL"] = NSStringFromCRHTTPVersion(self.currentRequest.version);
    env[@"REQUEST_URI"] = self.currentRequest.URL.absoluteString;
    env[@"DOCUMENT_URI"] = self.currentRequest.URL.path;
    env[@"SCRIPT_NAME"] = self.currentRequest.URL.path;
    env[@"QUERY_STRING"] = self.currentRequest.URL.query;
    env[@"REMOTE_ADDR"] = self.socket.connectedHost;
    env[@"REMOTE_PORT"] = @(self.socket.connectedPort);
    env[@"SERVER_ADDR"] = self.socket.localHost;
    env[@"SERVER_PORT"] = @(self.socket.localPort);
    [self.currentRequest setEnv:env];

    [super didReceiveCompleteRequestHeaders];

    CRHTTPServerConfiguration* config = (CRHTTPServerConfiguration*)self.server.configuration;
    requestBodyLength = [self.currentRequest valueForHTTPHeaderField:@"Content-Length"].integerValue;
    if ( requestBodyLength > 0 ) {
        NSUInteger bytesToRead = requestBodyLength < config.CRRequestBodyBufferSize ? requestBodyLength : config.CRRequestBodyBufferSize;
        [self.socket readDataToLength:bytesToRead withTimeout:config.CRHTTPConnectionReadBodyTimeout tag:CRHTTPConnectionSocketTagReadingRequestBody];
    } else {
        [self didReceiveCompleteRequest];
    }
}

- (void)didReceiveRequestBodyData:(NSData *)data {
    [super didReceiveRequestBodyData:data];
}

- (void)didReceiveCompleteRequest {
    [super didReceiveCompleteRequest];
}


#pragma mark - Responses

- (CRResponse *)responseWithHTTPStatusCode:(NSUInteger)HTTPStatusCode description:(NSString *)description version:(CRHTTPVersion)version {
    return [[CRHTTPResponse alloc] initWithConnection:self HTTPStatusCode:HTTPStatusCode description:description version:version];
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData*)data withTag:(long)tag {

    didPerformInitialRead = YES;
    CRHTTPServerConfiguration* config = (CRHTTPServerConfiguration*)self.server.configuration;

    if ( tag == CRHTTPConnectionSocketTagBeginReadingRequest ) {

        NSData* spaceData = [@" " dataUsingEncoding:NSUTF8StringEncoding];
        BOOL result = YES;

        NSRange rangeOfFirstNewline = [data rangeOfData:[CRConnection CRLFData] options:0 range:NSMakeRange(0, data.length)];
        if ( rangeOfFirstNewline.location != NSNotFound ) {

            NSRange rangeOfFirstSpace = [data rangeOfData:spaceData options:0 range:NSMakeRange(0, rangeOfFirstNewline.location)];
            if ( rangeOfFirstSpace.location != NSNotFound ) {

                NSRange methodRange = NSMakeRange(0, rangeOfFirstSpace.location);

                if ( methodRange.length > 0 ) {
                    NSString * methodSpec = [[NSString alloc] initWithBytesNoCopy:(void *)data.bytes + methodRange.location length:methodRange.length encoding:NSUTF8StringEncoding freeWhenDone:NO];

                    CRHTTPMethod requestMethod = CRHTTPMethodMake(methodSpec);
                    if ( requestMethod != CRHTTPMethodNone ) {

                        NSRange pathSearchRange = NSMakeRange(rangeOfFirstSpace.location + rangeOfFirstSpace.length, rangeOfFirstNewline.location - rangeOfFirstSpace.location - rangeOfFirstSpace.length);
                        NSRange rangeOfSecondSpace = [data rangeOfData:spaceData options:0 range:pathSearchRange];

                        if ( rangeOfSecondSpace.location != NSNotFound ) {

                            NSRange pathRange = NSMakeRange(pathSearchRange.location, rangeOfSecondSpace.location - pathSearchRange.location);
                            if ( pathRange.length > 0 ) {

                                NSString* pathSpec = [[NSString alloc] initWithBytesNoCopy:(void *)data.bytes + pathRange.location length:pathRange.length encoding:NSUTF8StringEncoding freeWhenDone:NO];

                                NSRange versionRange = NSMakeRange(rangeOfSecondSpace.location + rangeOfSecondSpace.length, rangeOfFirstNewline.location - rangeOfSecondSpace.location - rangeOfSecondSpace.length);

                                if ( versionRange.length > 0 ) {
                                    NSString* versionSpec = [[NSString alloc] initWithBytesNoCopy:(void *)data.bytes + versionRange.location length:versionRange.length encoding:NSUTF8StringEncoding freeWhenDone:NO];
                                    CRHTTPVersion version = CRHTTPVersionMake(versionSpec);


                                    NSRange rangeOfHostHeader = [data rangeOfData:[@"Host: " dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)];

                                    if ( rangeOfHostHeader.location != NSNotFound || version == CRHTTPVersion1_0 ) {

                                        NSRange rangeOfNewLineAfterHost = [data rangeOfData:[CRConnection CRLFData] options:0 range:NSMakeRange(rangeOfHostHeader.location + rangeOfHostHeader.length, data.length - rangeOfHostHeader.location - rangeOfHostHeader.length)];

                                        if ( rangeOfNewLineAfterHost.location == NSNotFound ) {
                                            rangeOfNewLineAfterHost.location = data.length - 1;
                                        }

                                        NSRange hostSpecRange = NSMakeRange(rangeOfHostHeader.location + rangeOfHostHeader.length, rangeOfNewLineAfterHost.location - rangeOfHostHeader.location - rangeOfHostHeader.length);
                                        NSString* hostSpec = [[NSString alloc] initWithBytesNoCopy:(void *)data.bytes + hostSpecRange.location length:hostSpecRange.length encoding:NSUTF8StringEncoding freeWhenDone:NO];

                                        // TODO: request.URL should be parsed using no memcpy and using the actual scheme
                                        NSURL* URL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@", hostSpec, pathSpec]];
                                        self.currentRequest = [[CRRequest alloc] initWithMethod:CRHTTPMethodMake(methodSpec) URL:URL version:CRHTTPVersionMake(versionSpec) connection:self];
                                    } else {
                                        result = NO;
                                    }
                                } else {
                                    result = NO;
                                }

                            } else {
                                result = NO;
                            }
                            
                            
                            
                            
                        } else {
                            result = NO;
                        }
                    } else {
                        result = NO;
                    }
                } else {
                    result = NO;
                }
            } else {
                result = NO;
            }
        } else {
            result = NO;
        }

//        NSArray<NSString*>* decodedHeaderLines = [decodedHeaders componentsSeparatedByString:@"\r\n"];
//        NSString* decodedHeadersFirstLine = decodedHeaderLines[0];
//        NSArray<NSString*>* decodedHeaderComponents = [decodedHeadersFirstLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
//
//        if ( decodedHeaderComponents.count == 3 ) {
//            NSString *methodSpec = decodedHeaderComponents[0];
//            NSString *path = decodedHeaderComponents[1];
//            NSString *versionSpec = decodedHeaderComponents[2];
//            __block NSString *host;
//
//            // Get the "Host" header
//            [decodedHeaderLines enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
//                if ( [obj hasPrefix:@"Host: "] ) {
//                    host = [[obj substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
//                    *stop = YES;
//                }
//            }];
//            NSURL* URL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@", host, path]];
//            self.currentRequest = [[CRRequest alloc] initWithMethod:CRHTTPMethodMake(methodSpec) URL:URL version:CRHTTPVersionMake(versionSpec) connection:self];
//        } else {
//            [self.socket disconnectAfterWriting];
//        }

        if ( !result ) {
            [self.socket disconnectAfterWriting];
            return;
        }


        if ( ! [self.currentRequest appendData:data] ) {
            [self.socket disconnectAfterWriting];
            return;
        }

        // We've read the request headers
        if ( self.currentRequest.headersComplete ) {
            [self didReceiveCompleteRequestHeaders];
        } else {
            // The request is malformed
            [self.socket disconnectAfterWriting];
            return;
        }

    } else if ( tag == CRHTTPConnectionSocketTagReadingRequestBody ) {

        // We are receiving data
        requestBodyReceivedBytesLength += data.length;
        [self didReceiveRequestBodyData:data];

        if (requestBodyReceivedBytesLength < requestBodyLength) {
            NSUInteger requestBodyLeftBytesLength = requestBodyLength - requestBodyReceivedBytesLength;
            NSUInteger bytesToRead = requestBodyLeftBytesLength < config.CRRequestBodyBufferSize ? requestBodyLeftBytesLength : config.CRRequestBodyBufferSize;
            [self.socket readDataToLength:bytesToRead withTimeout:config.CRHTTPConnectionReadBodyTimeout tag:CRHTTPConnectionSocketTagReadingRequestBody];
        } else {
            [self didReceiveCompleteRequest];
        }
    }
}

@end
