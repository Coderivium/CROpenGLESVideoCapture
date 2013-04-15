//
//  AudioWriter.h
//  OpenGLTutorialProject
//
//  Created by Dmitry Utenkov on 27.02.13.
//  Copyright (c) 2013 Dmitry Utenkov. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AudioWriter : NSObject 

@property (nonatomic, retain) NSURL *outputAudioFile;

- (void)startRecording;
- (void)stopRecording;

@end
