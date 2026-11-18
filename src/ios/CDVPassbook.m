/*
 * CDVPassbook.m
 *
 * Version 0.3.0 : correctifs pour cordova-ios 8 et les SDK iOS récents.
 *  - La fenêtre Wallet est affichée depuis le view controller Cordova du plugin
 *    (au lieu de keyWindow, peu fiable depuis l'adoption des scenes iOS par cordova-ios 8).
 *  - openPass utilise openURL:options:completionHandler: (openURL: ne fait plus rien
 *    avec le SDK iOS 18 et plus).
 *  - Gestion de la navigation adaptée au WKWebView : seuls les liens .pkpass sont
 *    interceptés, toutes les autres navigations sont autorisées.
 *  - Lecture des fichiers et téléchargements hors du fil principal (NSURLSession).
 *  - Plus de plantage quand passURL est nil (ex. : l'utilisateur annule l'ajout).
 *  - Imports explicites (cordova-ios 8 n'a plus de prefix header, CDV.h est déprécié).
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PassKit/PassKit.h>
#import <Cordova/Cordova.h>
#import "CDVPassbook.h"

typedef void (^AddPassResultBlock)(PKPass *pass, BOOL added);
typedef void (^PassErrorBlock)(NSError *error);

static NSString * const CDVPassbookErrorDomain = @"CDVPassbook";

@interface CDVPassbook () <PKAddPassesViewControllerDelegate>

@property (nonatomic, strong) PKPass *lastPass;
@property (nonatomic, copy) AddPassResultBlock lastAddPassCallback;

@end

@implementation CDVPassbook

#pragma mark - Navigation (liens .pkpass dans le WebView)

// Retourne YES pour AUTORISER la navigation, NO pour l'annuler.
- (BOOL)cdvPassbook_shouldAllowRequest:(NSURLRequest *)request
{
    if ([CDVPassbook available] && [request.URL.pathExtension.lowercaseString isEqualToString:@"pkpass"]) {
        // On télécharge le pass nous-mêmes et on empêche le WebView de naviguer vers le fichier.
        [self downloadPass:request.URL headers:nil success:nil error:nil];
        return NO;
    }
    return YES;
}

// cordova-ios 8 et plus
- (BOOL)shouldOverrideLoadWithRequest:(NSURLRequest *)request navigationType:(int)navigationType info:(NSDictionary *)navInfo
{
    return [self cdvPassbook_shouldAllowRequest:request];
}

#if !(defined(__CORDOVA_8_0_0) && CORDOVA_VERSION_MIN_REQUIRED >= __CORDOVA_8_0_0)
// cordova-ios 7 et moins (méthode dépréciée en 8, donc compilée seulement pour les versions antérieures)
- (BOOL)shouldOverrideLoadWithRequest:(NSURLRequest *)request navigationType:(int)navigationType
{
    return [self cdvPassbook_shouldAllowRequest:request];
}
#endif

#pragma mark - Disponibilité

+ (BOOL)available
{
    return [PKPassLibrary isPassLibraryAvailable] && [PKAddPassesViewController canAddPasses];
}

- (void)available:(CDVInvokedUrlCommand *)command
{
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:[CDVPassbook available]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

#pragma mark - Actions JavaScript

- (void)downloadPass:(CDVInvokedUrlCommand *)command
{
    if (![self ensureAvailability:command]) {
        return;
    }

    id callData = [command argumentAtIndex:0];
    NSURL *url = nil;
    NSDictionary *headers = nil;

    if ([callData isKindOfClass:[NSDictionary class]]) {
        id urlValue = callData[@"url"];
        if ([urlValue isKindOfClass:[NSString class]]) {
            url = [NSURL URLWithString:urlValue];
        }
        id headersValue = callData[@"headers"];
        if ([headersValue isKindOfClass:[NSDictionary class]]) {
            headers = headersValue;
        }
    } else if ([callData isKindOfClass:[NSString class]]) {
        url = [NSURL URLWithString:callData];
    }

    if (!url) {
        [self sendStatus:CDVCommandStatus_MALFORMED_URL_EXCEPTION message:nil command:command];
        return;
    }

    [self downloadPass:url headers:headers success:^(PKPass *pass, BOOL added) {
        [self sendPassResult:pass added:added command:command];
    } error:^(NSError *error) {
        [self sendError:error command:command];
    }];
}

- (void)addPass:(CDVInvokedUrlCommand *)command
{
    if (![self ensureAvailability:command]) {
        return;
    }

    id fileArg = [command argumentAtIndex:0];
    if (![fileArg isKindOfClass:[NSString class]] || [fileArg length] == 0) {
        [self sendStatus:CDVCommandStatus_ERROR message:@"no file provided" command:command];
        return;
    }

    NSURL *url = [NSURL URLWithString:fileArg];
    if (!url) {
        [self sendStatus:CDVCommandStatus_ERROR message:@"no valid file provided" command:command];
        return;
    }

    // Lecture du fichier hors du fil principal (évite le « THREAD WARNING »).
    [self.commandDelegate runInBackground:^{
        NSData *data = [NSData dataWithContentsOfURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!data) {
                [self sendStatus:CDVCommandStatus_IO_EXCEPTION message:@"could not read pass file" command:command];
                return;
            }
            [self tryAddPass:data success:^(PKPass *pass, BOOL added) {
                [self sendPassResult:pass added:added command:command];
            } error:^(NSError *error) {
                [self sendError:error command:command];
            }];
        });
    }];
}

- (void)openPass:(CDVInvokedUrlCommand *)command
{
    if (![self ensureAvailability:command]) {
        return;
    }

    NSURL *url = nil;
    id argument = [command argumentAtIndex:0];
    if ([argument isKindOfClass:[NSDictionary class]]) {
        id passURL = argument[@"passURL"];
        if ([passURL isKindOfClass:[NSString class]]) {
            url = [NSURL URLWithString:passURL];
        }
    } else if ([argument isKindOfClass:[NSString class]]) {
        url = [NSURL URLWithString:argument];
    } else {
        [self sendStatus:CDVCommandStatus_ERROR message:@"No Pass URL provided" command:command];
        return;
    }

    if (!url) {
        [self sendStatus:CDVCommandStatus_MALFORMED_URL_EXCEPTION message:nil command:command];
        return;
    }

    // openURL: est obsolète et ne fait plus rien avec le SDK iOS 18 et plus.
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) {
            [self sendStatus:CDVCommandStatus_OK message:nil command:command];
        } else {
            [self sendStatus:CDVCommandStatus_ERROR message:@"Could not open Pass" command:command];
        }
    }];
}

#pragma mark - Résultats

- (BOOL)ensureAvailability:(CDVInvokedUrlCommand *)command
{
    if (![CDVPassbook available]) {
        [self sendStatus:CDVCommandStatus_INVALID_ACTION message:@"Passbook is not available on this device" command:command];
        return NO;
    }
    return YES;
}

- (void)sendStatus:(CDVCommandStatus)status message:(NSString *)message command:(CDVInvokedUrlCommand *)command
{
    CDVPluginResult *result = message
        ? [CDVPluginResult resultWithStatus:status messageAsString:message]
        : [CDVPluginResult resultWithStatus:status];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendPassResult:(PKPass *)pass added:(BOOL)added command:(CDVInvokedUrlCommand *)command
{
    // Les valeurs nil feraient planter le littéral NSDictionary : on les remplace.
    NSDictionary *data = @{
        @"added": @(added),
        @"pass": @{
            @"passTypeIdentifier": pass.passTypeIdentifier ?: @"",
            @"serialNumber": pass.serialNumber ?: @"",
            @"passURL": pass.passURL.absoluteString ?: [NSNull null]
        }
    };
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:data];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendError:(NSError *)error command:(CDVInvokedUrlCommand *)command
{
    NSString *message = error.localizedDescription ?: @"Unknown error";
    [self sendStatus:CDVCommandStatus_ERROR message:message command:command];
}

#pragma mark - Ajout du pass

// À appeler sur le fil principal (affiche une interface).
- (void)tryAddPass:(NSData *)data success:(AddPassResultBlock)successBlock error:(PassErrorBlock)errorBlock
{
    NSError *error = nil;
    PKPass *pass = [[PKPass alloc] initWithData:data error:&error];
    if (!pass) {
        if (errorBlock) {
            errorBlock(error ?: [NSError errorWithDomain:CDVPassbookErrorDomain code:1
                                                userInfo:@{NSLocalizedDescriptionKey: @"Invalid pass data"}]);
        }
        return;
    }

    PKAddPassesViewController *controller = [[PKAddPassesViewController alloc] initWithPass:pass];
    if (!controller) {
        if (errorBlock) {
            errorBlock([NSError errorWithDomain:CDVPassbookErrorDomain code:2
                                       userInfo:@{NSLocalizedDescriptionKey: @"Could not create the Wallet view"}]);
        }
        return;
    }

    UIViewController *presenter = [self getTopMostViewController];
    if (!presenter || presenter.view.window == nil) {
        if (errorBlock) {
            errorBlock([NSError errorWithDomain:CDVPassbookErrorDomain code:3
                                       userInfo:@{NSLocalizedDescriptionKey: @"No visible view controller to present the Wallet view"}]);
        }
        return;
    }

    self.lastPass = pass;
    self.lastAddPassCallback = successBlock;
    controller.delegate = self;
    [presenter presentViewController:controller animated:YES completion:nil];
}

// Part du view controller Cordova du plugin (compatible avec les scenes iOS).
- (UIViewController *)getTopMostViewController
{
    UIViewController *top = self.viewController;
    while (top.presentedViewController != nil && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)downloadPass:(NSURL *)url
             headers:(NSDictionary *)headers
             success:(AddPassResultBlock)successBlock
               error:(PassErrorBlock)errorBlock
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:20.0];
    // User-Agent de type Passbook, pour que certains serveurs renvoient directement le .pkpass.
    [request setValue:@"Passbook/1.0 CFNetwork/672.0.2 Darwin/14.0.0" forHTTPHeaderField:@"User-Agent"];
    for (id key in headers) {
        id value = headers[key];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
            [request setValue:value forHTTPHeaderField:key];
        }
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *connectionError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (connectionError) {
                if (errorBlock) errorBlock(connectionError);
                return;
            }
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                if (status < 200 || status >= 300) {
                    if (errorBlock) {
                        NSString *message = [NSString stringWithFormat:@"Pass download failed (HTTP %ld)", (long)status];
                        errorBlock([NSError errorWithDomain:CDVPassbookErrorDomain code:status
                                                   userInfo:@{NSLocalizedDescriptionKey: message}]);
                    }
                    return;
                }
            }
            [self tryAddPass:data success:successBlock error:errorBlock];
        });
    }];
    [task resume];
}

#pragma mark - PKAddPassesViewControllerDelegate

- (void)addPassesViewControllerDidFinish:(PKAddPassesViewController *)controller
{
    PKPass *pass = self.lastPass;
    AddPassResultBlock callback = self.lastAddPassCallback;
    self.lastPass = nil;
    self.lastAddPassCallback = nil;

    [controller dismissViewControllerAnimated:YES completion:^{
        if (callback && pass) {
            BOOL passAdded = [[[PKPassLibrary alloc] init] containsPass:pass];
            callback(pass, passAdded);
        }
    }];
}

@end
