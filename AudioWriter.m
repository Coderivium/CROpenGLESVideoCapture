//
//  AudioWriter.m
//  OpenGLTutorialProject
//
//  Created by Dmitry Utenkov on 27.02.13.
//  Copyright (c) 2013 Dmitry Utenkov. All rights reserved.
//

#import "AudioWriter.h"
#import <AVFoundation/AVFoundation.h>

@interface AudioWriter() <AVAudioRecorderDelegate> {
    AVAudioRecorder *recorder;
}

@end

@implementation AudioWriter

- (id)init {
    if (self = [super init]) {
        //Instanciate an instance of the AVAudioSession object.
        AVAudioSession * audioSession = [AVAudioSession sharedInstance];
        //Setup the audioSession for playback and record.
        //We could just use record and then switch it to playback leter, but
        //since we are going to do both lets set it up once.
        [audioSession setCategory:AVAudioSessionCategoryRecord error:nil];
        //Activate the session
        [audioSession setActive:YES error:nil];
    }
    return self;
}

- (void)startRecording {
    if (![self outputAudioFile]) {
        NSString *audioFilePath = [NSString stringWithFormat:@"%@/Documents/sound.m4a", NSHomeDirectory()];
        NSURL *outputURL = [NSURL fileURLWithPath:audioFilePath];
        [self setOutputAudioFile:outputURL];
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self outputAudioFile] path]]) {
        [[NSFileManager defaultManager] removeItemAtURL:[self outputAudioFile] error:nil];
    }
    
    NSDictionary*  audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                          [NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                                          [NSNumber numberWithInt:2],                    AVNumberOfChannelsKey,
                                          [NSNumber numberWithFloat:44100.0],            AVSampleRateKey,
                                          [NSNumber numberWithInt:64000],                AVEncoderBitRateKey,
                                          nil];
    
    NSError *error = nil;
    recorder = [[ AVAudioRecorder alloc] initWithURL:[self outputAudioFile] settings:audioOutputSettings error:&error];
    
    [recorder setDelegate:self];
    [recorder prepareToRecord];
    [recorder record];
}

- (void)stopRecording {
    [recorder stop];
}

@end
