#import "TOCFuture+MoreContructors.h"
#import "TOCFuture+MoreContinuations.h"
#import "TOCInternal.h"
#import "NSArray+TOCFuture.h"

@implementation TOCFuture (MoreConstructors)

+(TOCFuture*) futureWithTimeoutFailure {
    return [TOCFuture futureWithFailure:[TOCTimeout new]];
}

+(TOCFuture*) futureWithCancelFailure {
    return [TOCFuture futureWithFailure:TOCCancelToken.cancelledToken];
}

+(TOCFuture*) futureWithResultFromOperation:(id (^)(void))operation
                          dispatchedOnQueue:(dispatch_queue_t)queue {
    TOC_require(operation != nil);
    
    TOCFutureSource* resultSource = [TOCFutureSource new];
    
    dispatch_async(queue, ^{ [resultSource forceSetResult:operation()]; });
    
    return resultSource.future;
}
+(TOCFuture*) futureWithResultFromOperation:(id(^)(void))operation
                            invokedOnThread:(NSThread*)thread {
    TOC_require(operation != nil);
    TOC_require(thread != nil);
    
    TOCFutureSource* resultSource = [TOCFutureSource new];
    
    [TOCInternal_BlockObject performBlock:^{ [resultSource forceSetResult:operation()]; }
                                 onThread:thread];
    
    return resultSource.future;
}

+(TOCFuture*) futureWithResult:(id)resultValue
                    afterDelay:(NSTimeInterval)delayInSeconds {
    return [self futureWithResult:resultValue
                       afterDelay:delayInSeconds
                           unless:nil];
}
+(TOCFuture*) futureWithResult:(id)resultValue
                    afterDelay:(NSTimeInterval)delayInSeconds
                        unless:(TOCCancelToken*)unlessCancelledToken {
    TOC_require(delayInSeconds >= 0);
    TOC_require(!isnan(delayInSeconds));
    
    if (delayInSeconds == 0) return [TOCFuture futureWithResult:resultValue];
    __block id resultValueBlock = resultValue;
    
    TOCFutureSource* resultSource = [TOCFutureSource new];
    if (delayInSeconds == INFINITY) return [resultSource.future unless:unlessCancelledToken];
    
    double delayInNanoseconds = delayInSeconds * NSEC_PER_SEC;
    TOC_require(delayInNanoseconds < INT64_MAX/2);
    
    dispatch_time_t then = dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayInNanoseconds);
    dispatch_after(then, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [resultSource trySetResult:resultValueBlock];
    });
    [unlessCancelledToken whenCancelledDo:^{
        if ([resultSource trySetFailedWithCancel]) {
            resultValueBlock = nil;
        }
    }];
    
    
    return resultSource.future;
}

+(TOCFuture*) futureWithResultFromAsyncOperationWithResultLastingUntilCancelled:(TOCAsyncOperationWithResultLastingUntilCancelled)asyncOperationWithResultLastingUntilCancelled
                                                           withOperationTimeout:(NSTimeInterval)timeoutPeriodInSeconds
                                                                          until:(TOCCancelToken*)untilCancelledToken {
    TOC_require(asyncOperationWithResultLastingUntilCancelled != nil);
    TOC_require(timeoutPeriodInSeconds >= 0);
    TOC_require(!isnan(timeoutPeriodInSeconds));
    
    if (timeoutPeriodInSeconds == 0) {
        return [TOCFuture futureWithTimeoutFailure];
    }
    if (timeoutPeriodInSeconds == INFINITY) {
        return asyncOperationWithResultLastingUntilCancelled(untilCancelledToken);
    }
    
    TOCAsyncOperationWithResultLastingUntilCancelled timeoutOperation = ^(TOCCancelToken* internalUntilCancelledToken) {
        return [TOCFuture futureWithResult:@[[TOCFuture futureWithTimeoutFailure]]
                                afterDelay:timeoutPeriodInSeconds
                                    unless:internalUntilCancelledToken];
    };
    TOCAsyncOperationWithResultLastingUntilCancelled wrappedOperation = ^(TOCCancelToken* internalUntilCancelledToken) {
        return [asyncOperationWithResultLastingUntilCancelled(internalUntilCancelledToken) finally:^(TOCFuture *completed) {
            return @[completed];
        }];
    };
    
    NSArray* racingOperations = @[wrappedOperation, timeoutOperation];
    TOCFuture* winner = [racingOperations asyncRaceOperationsWithWinningResultLastingUntil:untilCancelledToken];
    return [winner then:^(NSArray* wrappedResult) {
        return wrappedResult[0];
    }];
}

+(TOCFuture*) futureWithResultFromAsyncCancellableOperation:(TOCAsyncCancellableOperation)asyncCancellableOperation
                                                withTimeout:(NSTimeInterval)timeoutPeriodInSeconds
                                                     unless:(TOCCancelToken*)unlessCancelledToken {
    TOC_require(asyncCancellableOperation != nil);
    TOC_require(timeoutPeriodInSeconds >= 0);
    TOC_require(!isnan(timeoutPeriodInSeconds));
    
    if (timeoutPeriodInSeconds == 0) {
        return [TOCFuture futureWithTimeoutFailure];
    }
    if (timeoutPeriodInSeconds == INFINITY) {
        return asyncCancellableOperation(unlessCancelledToken);
    }
    
    // start the timeout countdown, making sure it cancels if the caller cancels
    TOCFuture* futureTimeout = [TOCFuture futureWithResult:nil
                                                afterDelay:timeoutPeriodInSeconds
                                                    unless:unlessCancelledToken];
    
    // start the operation, ensuring it cancels if the timeout finishes or is cancelled
    TOCFuture* futureOperationResult = asyncCancellableOperation(futureTimeout.cancelledOnCompletionToken);
    
    // wait for the operation to finish or be cancelled or timeout
    return [futureOperationResult finally:^(TOCFuture* completedOperationResult) {
        // detect when cancellation was due to timeout, and report appropriately
        bool wasCancelled = completedOperationResult.hasFailedWithCancel;
        bool wasNotCancelledExternally = !unlessCancelledToken.isAlreadyCancelled;
        bool wasTimeout = wasCancelled && wasNotCancelledExternally;
        if (wasTimeout) {
            return [TOCFuture futureWithTimeoutFailure];
        }
        
        return completedOperationResult;
    }];
}

+(TOCFuture*) futureWithResultFromAsyncCancellableOperation:(TOCAsyncCancellableOperation)asyncCancellableOperation
                                                withTimeout:(NSTimeInterval)timeoutPeriodInSeconds {
    TOC_require(asyncCancellableOperation != nil);
    TOC_require(timeoutPeriodInSeconds >= 0);
    TOC_require(!isnan(timeoutPeriodInSeconds));
    
    return [self futureWithResultFromAsyncCancellableOperation:asyncCancellableOperation
                                                   withTimeout:timeoutPeriodInSeconds
                                                        unless:nil];
}

@end
