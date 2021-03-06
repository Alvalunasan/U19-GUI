function code = noworld_laser
% poisson_towers   Code for the ViRMEn experiment poisson_towers.
%   code = poisson_towers   Returns handles to the functions that ViRMEn
%   executes during engine initialization, runtime and termination.

  % Begin header code - DO NOT EDIT
  code.initialization = @initializationCodeFun;
  code.runtime        = @runtimeCodeFun;
  code.termination    = @terminationCodeFun;
  % End header code - DO NOT EDIT

  code.setup          = @setupTrials;

end


%%_________________________________________________________________________
% --- INITIALIZATION code: executes before the ViRMEn engine starts.
function vr = initializationCodeFun(vr)
  rng('shuffle')
  
  % Standard communications lines for VR rig
  vr    = initializeVRRig_laser(vr, vr.exper.userdata.trainee);

  % Initialize standard state control variables
  vr    = initializeGradedExperiment(vr);

  % Receive experiment parameters through TCP/IP from laser/galvo PC
  vr    = receiveExptParams(vr);
  
  % Number and sequence of trials, reward level etc.
  vr    = setupTrials(vr);


  %****** DEBUG DISPLAY ******
  if ~RigParameters.hasDAQ && ~RigParameters.simulationMode
    vr.text(1).position     = [-1 0.7];
    vr.text(1).size         = 0.03;
    vr.text(1).color        = [1 1 0];
    vr.text(2).position     = [-1 0.65];
    vr.text(2).size         = 0.03;
    vr.text(2).color        = [1 1 0];
    vr.text(3).position     = [-1.6 0.9];
    vr.text(3).size         = 0.02;
    vr.text(3).color        = [1 1 0];
    vr.text(4).position     = [-1.6 0.85];
    vr.text(4).size         = 0.02;
    vr.text(4).color        = [1 1 0];
  end
  %***************************

end


%%_________________________________________________________________________
% --- RUNTIME code: executes on every iteration of the ViRMEn engine.
function vr = runtimeCodeFun(vr)
try
    
  % Handle keyboard, remote input, wait times
  vr  = processKeypress(vr, vr.protocol);
  if vr.waitTime ~= 0
    [vr.waitStart, vr.waitTime] = processWaitTimes(vr.waitStart, vr.waitTime);
  end
  vr.prevState  = vr.state;
  
  % Forced termination
  if isinf(vr.protocol.endExperiment)
    % send out digital words for laser/galvo control and sync
    vr.dataOut(RigParameters.locationChannels+1) = vr.laser.posOut;
    binState = dec2bin(virmenStateCodes.EndOfExperiment,numel(RigParameters.virmenStateChannels));
    for jj = 1:numel(RigParameters.virmenStateChannels)
       vr.dataOut(RigParameters.virmenStateChannels(jj)+numel(RigParameters.locationChannels)) = str2double(binState(jj));
    end
    nidaqDOwrite2ports('writeDO',vr.dataOut);
  
    vr.experimentEnded  = true;
  elseif vr.waitTime == 0   % Only if not in a time-out period...
  switch vr.state           % ... take action depending on the simulation state

    %========================================================================
    case BehavioralState.SetupTrial
      % Configure world for the trial; this is done separately from 
      % StartOfTrial as it can take a long time and we want to teleport the
      % animal back to the start location only after this has been completed
      % and the Virmen engine can do whatever behind-the-scenes magic. If we
      % try to merge this step with StartOfTrial, animal motion can
      % accumulate during initialization and result in an artifact where the
      % animal is suddenly displaced forward upon start of world display.
      vr.stateCode          = virmenStateCodes.SetUpTrial;
      vr                    = initializeTrialWorld(vr);
      
      % just for this behavioral state (which is when trials are drawn), it
      % makes sense to send the data before anything since here there is a
      % handshake between the two PCs, and LASERGALVO needs to know we're
      % here in order to save trial data. Data isn't saved at the end of
      % the trial because we want the possibility of having ITI stimulation
      vr.dataOut(RigParameters.locationChannels+1) = zeros(1,numel(RigParameters.locationChannels));
      binState = dec2bin(vr.stateCode,numel(RigParameters.virmenStateChannels));
      for jj = 1:numel(RigParameters.virmenStateChannels)
          vr.dataOut(RigParameters.virmenStateChannels(jj)+numel(RigParameters.locationChannels)) = str2double(binState(jj));
      end
      nidaqDOwrite2ports('writeDO',vr.dataOut);
      
      % wait until laser PC has saved data and sent ttl saying it's
      % OK to proceed
      vr.laser.proceed = 0;
      while ~ vr.laser.proceed
          data = nidaqDIread('readDI'); % receive ttl from laser PC
          vr.laser.proceed = data(RigParameters.saveChIdx);
      end
      
      if vr.protocol.endExperiment == true
        % Allow end of experiment only after completion of the last trial
        vr.experimentEnded  = true;
      elseif ~vr.experimentEnded
        vr.state            = BehavioralState.InitializeTrial;
        vr                  = teleportToStart(vr);
      end
      

    %========================================================================
    case BehavioralState.InitializeTrial
      % Teleport to start and send signals indicating start of trial
      vr.stateCode          = virmenStateCodes.InitializeTrial;
      vr                    = teleportToStart(vr);
      vr                    = startVRTrial(vr);
      prevDuration          = vr.logger.logStart(vr);
      vr.protocol.recordTrialDuration(prevDuration);

      % Make the world visible
      vr.state              = BehavioralState.StartOfTrial;
      vr.worlds{vr.currentWorld}.surface.visible = vr.defaultVisibility;

          
    %========================================================================
    case BehavioralState.StartOfTrial
      % We keep the animal at the start of the track for the first iteration of the trial where 
      % the world is actually visible. This is only as a safety factor in case the first rendering
      % (caching) of the world graphics makes the previous iteration take unusually long, in which
      % case displacement is accumulated without the animal actually responding to anything.
      vr.stateCode          = virmenStateCodes.StartOfTrial;
      vr.state              = BehavioralState.WithinTrial;
      vr                    = teleportToStart(vr);

      
    %========================================================================
    case BehavioralState.WithinTrial
      
      vr.stateCode          = virmenStateCodes.WithinTrial;
      % Reset sound counter if no longer relevant
      if ~isempty(vr.soundStart) && toc(vr.soundStart) > vr.punishment.duration
        vr.soundStart       = [];
      end
      
      % deliver reward at the end of each trial (15s)
      idx = find(vr.logger.currentTrial.time>0,1,'last');
      if ~isempty(idx)
          if vr.logger.currentTrial.time(idx) >= 15
              vr.choice           = vr.trialType;
              vr.state            = BehavioralState.ChoiceMade;
          end
      end

    %========================================================================
    case BehavioralState.ChoiceMade
       
      vr.stateCode          = virmenStateCodes.ChoiceMade;
      
      % Log the end of the trial
      vr.excessTravel = vr.logger.distanceTraveled() / vr.mazeLength - 1;
      vr.logger.logEnd(vr);

      % Handle reward/punishment and end of trial pause
      vr = judgeVRTrial(vr);
      
      % Update movement data display
      rawVel      = double(vr.logger.currentTrial.sensorDots(1:vr.logger.currentTrial.iterations, [4 3]));
      vr.protocol.updateRun ( vr.logger.currentTrial.position       ...
                            , vr.logger.currentTrial.velocity       ...
                            , atan2(-rawVel(:,1).*sign(rawVel(:,2)), abs(rawVel(:,2)))   ... HACK: bottom sensor specific!
                            );



    %========================================================================
    case BehavioralState.DuringReward
      % This intermediate state is necessary so that whatever changes to the
      % ViRMen world upon rewarded behavior is applied before entering the
      % end of trial wait period
      
      vr.stateCode          = virmenStateCodes.DuringReward;
      vr = rewardVRTrial(vr, vr.rewardFactor);

      % For human testing, flash the screen green if correct and red if wrong
      if ~RigParameters.hasDAQ && ~RigParameters.simulationMode
        if vr.choice == vr.trialType
          vr.worlds{vr.currentWorld}.backgroundColor  = [0 1 0] * 0.8;
        elseif vr.choice == vr.wrongChoice
          vr.worlds{vr.currentWorld}.backgroundColor  = [1 0 0] * 0.8;
        else
          vr.worlds{vr.currentWorld}.backgroundColor  = [0 0.5 1] * 0.8;
        end
      end


    %========================================================================
    case BehavioralState.EndOfTrial
      % Send signals indicating end of trial and start inter-trial interval  
      vr.stateCode          = virmenStateCodes.EndOfTrial;
      vr = endVRTrial(vr);    


    %========================================================================
    case BehavioralState.InterTrial
      % Handle input of comments etc.
      vr.stateCode          = virmenStateCodes.InterTrial;
      vr.logger.logExtras(vr, vr.rewardFactor);
      vr.state    = BehavioralState.SetupTrial;
      if ~RigParameters.hasDAQ
        vr.worlds{vr.currentWorld}.backgroundColor  = [0 0 0];
      end

      % Record performance for the trial
      vr.protocol.recordChoice( vr.choice                                   ...
                              , vr.rewardFactor * RigParameters.rewardSize  ...
                              , vr.trialWeight                              ...
                              , vr.excessTravel < vr.maxExcessTravel        ...
                              , vr.logger.trialLength()                     ...
                              , cellfun(@numel, vr.cuePos)                  ...
                              );

      % Decide duration of inter trial interval
      if vr.choice == vr.trialType
        vr.waitTime       = vr.itiCorrectDur;
      else
        vr.waitTime       = vr.itiWrongDur;
      end



    %========================================================================
    case BehavioralState.EndOfExperiment
      vr.stateCode          = virmenStateCodes.EndOfExperiment;
      
      % also for this behavioral state (which is when trials are drawn), it
      % makes sense to send the data before anything since here there is a
      % handshake between the two PCs, and LASERGALVO needs to know we're
      % here in order to save trial data. Data isn't saved at the end of
      % the trial because we want the possibility of having ITI stimulation
      vr.dataOut(RigParameters.locationChannels+1) = zeros(1,numel(RigParameters.locationChannels));
      binState = dec2bin(vr.stateCode,numel(RigParameters.virmenStateChannels));
      for jj = 1:numel(RigParameters.virmenStateChannels)
          vr.dataOut(RigParameters.virmenStateChannels(jj)+numel(RigParameters.locationChannels)) = str2double(binState(jj));
      end
      nidaqDOwrite2ports('writeDO',vr.dataOut);
      
      vr.experimentEnded    = true;

  end
  end                     % Only if not in time-out period

  vr.lastDP               = vr.dp;
  
  % decide what to do about the laser / galvo
  vr = lasercontroller(vr);
  
  % send out digital words for laser/galvo control and sync, 
  % receive copy of digital trigger sent to laser (sync)
  vr = lsrPC_DIO(vr);

  % IMPORTANT: Log position, velocity etc. at *every* iteration
  vr.logger.logTick(vr, vr.sensorData);
  vr.protocol.update();

%   % Send DAQ signals for multi-computer synchronization
%   updateDAQSyncSignals(vr.iterFcn([numel(vr.logger.block), vr.protocol.currentTrial, vr.logger.iterationStamp(vr)]));

  

  %****** DEBUG DISPLAY ******
  if ~RigParameters.hasDAQ && ~RigParameters.simulationMode
    vr.text(1).string   = num2str(vr.cueCombo(1,:));
    vr.text(2).string   = num2str(vr.cueCombo(2,:));
    vr.text(3).string   = num2str(vr.cuePos{1}, '%4.0f ');
    vr.text(4).string   = num2str(vr.cuePos{2}, '%4.0f ');
  end
  %***************************

  
catch err
  displayException(err);
  keyboard
  vr.experimentEnded    = true;
end
end

%%_________________________________________________________________________
% --- TERMINATION code: executes after the ViRMEn engine stops.
function vr = terminationCodeFun(vr)

 % send out digital words for laser/galvo control and sync
  vr.dataOut(RigParameters.locationChannels+1) = vr.laser.posOut;
  binState = dec2bin(virmenStateCodes.EndOfExperiment,numel(RigParameters.virmenStateChannels));
  for jj = 1:numel(RigParameters.virmenStateChannels)
      vr.dataOut(RigParameters.virmenStateChannels(jj)+numel(RigParameters.locationChannels)) = str2double(binState(jj));
  end
  nidaqDOwrite2ports('writeDO',vr.dataOut);
  
  % Stop user control via statistics display
  vr.protocol.stop();

  % Log various pieces of information
  if isfield(vr, 'logger') && ~isempty(vr.logger.logFile)
    % Save via logger first to discard empty records
    log = vr.logger.save(true, vr.timeElapsed, vr.protocol.getPlots());

    vr.exper.userdata.regiment.recordBehavior(vr.exper.userdata.trainee, log, vr.logger.newBlocks);
    vr.exper.userdata.regiment.save();
  end

  % Standard communications shutdown
  terminateVRRig_laser(vr);

end


%%_________________________________________________________________________
% --- (Re-)triangulate world and obtain various subsets of interest
function vr = computeWorld(vr)

  % Modify the ViRMen world to the specifications of the given maze; sets
  % vr.mazeID to the given mazeID
  [vr,lCue,stimParameters]  = configureMaze(vr, vr.mazeID, vr.mainMazeID);
  vr.mazeLength             = vr.lStart                                   ...
                            - vr.worlds{vr.currentWorld}.startLocation(2) ...
                            + vr.lCue                                     ...
                            + vr.lMemory                                  ...
                            + vr.lArm                                     ...
                            ;
  vr.stemLength             = vr.lCue                                     ...
                            + vr.lMemory                                  ...
                            ;

  % Specify parameters for computation of performance statistics
  % (maze specific for advancement criteria)
  criteria                  = vr.mazes(vr.mainMazeID).criteria;
  if vr.warmupIndex > 0
    vr.protocol.setupStatistics(criteria.warmupNTrials(vr.warmupIndex), 1, false);
  else
      if isnan(criteria.easyBlock)
        vr.protocol.setupStatistics(criteria.numTrials, 1, false);
      else
        vr.protocol.setupStatistics(criteria.numBlockTrials, 1, false);
      end
  end


  % Mouse is considered to have made a choice if it enters one of these areas
  vr.cross_choice           = getCrossingLine(vr, {'choiceLFloor', 'choiceRFloor'}, 1, @minabs);

  % Other regions of interest in the maze
  vr.cross_cue              = getCrossingLine(vr, {'cueFloor'}   , 2, @min);
  vr.cross_memory           = getCrossingLine(vr, {'memoryFloor'}, 2, @min);
  vr.cross_arms             = getCrossingLine(vr, {'armsFloor'}  , 2, @min);

  % Indices of left/right turn cues
  turnCues                  = {'leftTurnCues', 'rightTurnCues'};
  vr.tri_turnCue            = getVirmenFeatures('triangles', vr, turnCues);
  vr.tri_turnHint           = getVirmenFeatures('triangles', vr, {'leftTurnHint', 'rightTurnHint'} );
  vr.vtx_turnCue            = getVirmenFeatures('vertices' , vr, turnCues);
  vr.dynamicCueNames        = {'tri_turnCue'};
  vr.choiceHintNames        = {'tri_turnHint'};

  % Visibility of hints (visual guides)
  vr.hintVisibility         = nan(size(vr.choiceHintNames));
  for iCue = 1:numel(vr.choiceHintNames)
    vr.hintVisibility(iCue) = vr.mazes(vr.mazeID).visible.(vr.choiceHintNames{iCue});
  end
  
  % HACK to deduce which triangles belong to which tower -- they seem to be
  % ordered by column from empirical tests
  vr.tri_turnCue            = reshape(vr.tri_turnCue, size(vr.tri_turnCue,1), [], vr.nCueSlots);
  vr.vtx_turnCue            = reshape(vr.vtx_turnCue, size(vr.vtx_turnCue,1), [], vr.nCueSlots);
  vr.cueBlurred             = false(size(vr.vtx_turnCue));
  

  % Cache various properties of the loaded world (maze configuration) for speed
  vr                        = cacheMazeConfig(vr);
  vr.cueIndex               = zeros(1, numel(turnCues));
  vr.slotPos                = nan(numel(ChoiceExperimentStats.CHOICES), vr.nCueSlots);
  for iChoice = 1:numel(turnCues)
    vr.cueIndex(iChoice)    = vr.worlds{vr.currentWorld}.objects.indices.(turnCues{iChoice});
    cueObject               = vr.exper.worlds{vr.currentWorld}.objects{vr.cueIndex(iChoice)};
    vr.slotPos(iChoice,:)   = cueObject.y;
  end
  
  % Set and record template position of cues
  vr.template_turnCue       = nan(size(vr.vtx_turnCue));
  for iSide = 1:numel(turnCues)
    cueIndex                = vr.worlds{vr.currentWorld}.objects.indices.(turnCues{iSide});
    vertices                = vr.vtx_turnCue(iSide, :, :);
    vtxLoc                  = vr.worlds{vr.currentWorld}.surface.vertices(2,vertices);
    vtxLoc                  = reshape(vtxLoc, size(vertices));
    cueLoc                  = vr.exper.worlds{vr.currentWorld}.objects{cueIndex}.y;
    if ~isempty(vr.motionBlurRange)
      cueWidth              = vr.exper.worlds{vr.currentWorld}.objects{cueIndex}.height;
    else
      cueWidth              = 1;
    end
    
    vr.template_turnCue(iSide,:,:)  ...
                            = bsxfun(@minus, vtxLoc, shiftdim(cueLoc,-1)) / cueWidth;
  end
  
  % Set and record template color of cues
  if ~isempty(vr.motionBlurRange) && ~isnan(vr.dimCue)
    vr.color_turnCue        = vr.cueColor                               ...
                            * repmat( RigParameters.colorAdjustment     ...
                                    , 1, numel(vr.vtx_turnCue)          ...
                                    )                                   ...
                            ;
  end
  
  
  % Set up Poisson stimulus train
  [modified, vr.stimulusConfig] = vr.poissonStimuli.configure(lCue, stimParameters{:});
  if modified
    errordlg( sprintf('Stimuli parameters had to be configured for maze %d.', vr.mazeID)  ...
                     , 'Stimulus sequences not configured', 'modal'                       ...
            );
    vr.experimentEnded      = true;
    return;
  end
  
  vr.worlds{vr.currentWorld}.surface.colors = zeros(size(vr.worlds{vr.currentWorld}.surface.colors));

end


%%_________________________________________________________________________
% --- Modify the world for the next trial
function vr = initializeTrialWorld(vr)

  % Recompute world for the desired maze level if necessary
  [vr, mazeChanged]         = decideMazeAdvancement(vr, vr.numMazesInProtocol);
  if mazeChanged
    vr                      = computeWorld(vr);
    
    % The recomputed world should remain invisible until after the ITI
    vr.worlds{vr.currentWorld}.surface.visible(:) = false;
  end

  % Adjust the reward level and trial drawing method
  if mazeChanged
     if vr.updateReward % flag to update reward, won't do it during easy block
      vr.protocol.updateRewardScale(vr.warmupIndex, vr.mazeID);
    end
    if vr.warmupIndex > 0
      trialDrawMethod       = vr.exper.userdata.trainee.warmupDrawMethod;
    else
      trialDrawMethod       = vr.exper.userdata.trainee.mainDrawMethod;
    end
    vr.protocol.setDrawMethod(TrainingRegiment.(trialDrawMethod{1}){trialDrawMethod{2}});
  end


  % Select a trial type, i.e. whether the correct choice is left or right
  [success, vr.trialProb]   = vr.protocol.drawTrial(vr.mazeID, [-vr.lStart, vr.lCue + vr.lMemory + 40]);
  vr.experimentEnded        = ~success;
  vr.trialType              = Choice(vr.protocol);
  vr.wrongChoice            = setdiff(ChoiceExperimentStats.CHOICES, vr.trialType);

  % Flags for animal's progress through the maze
  vr.iCueEntry              = vr.iterFcn(0);
  vr.iMemEntry              = vr.iterFcn(0);
  vr.iArmEntry              = vr.iterFcn(0);

  % Cue presence on right and wrong sides
  [vr, vr.trialWeight]      = drawCueSequence(vr);

  % Visibility range of visual guides
  vr.hintVisibleFrom        = vr.hintVisibility;
  
  % Modify ViRMen world object visibilities and colors 
  vr                        = configureCues(vr);
  
  % Decide whether laser will be on or off, and where
  vr                        = drawLaserTrials(vr);

end

%%_________________________________________________________________________
% --- Draw a random cue sequence
function [vr, nonTrivial] = drawCueSequence(vr)

  % Common storage
  vr.cuePos                 = cell(size(ChoiceExperimentStats.CHOICES));
  vr.cueOnset               = cell(size(ChoiceExperimentStats.CHOICES));
  vr.cueOffset              = cell(size(ChoiceExperimentStats.CHOICES));
  vr.cueTime                = cell(size(ChoiceExperimentStats.CHOICES));    % Redundant w.r.t. cueOnset, but useful for checking duration
  vr.cueAppeared            = cell(size(ChoiceExperimentStats.CHOICES));

  % Obtain the next trial in the configured sequence, if available
  trial                     = vr.poissonStimuli.nextTrial();
  if isempty(trial)
    vr.experimentEnded      = true;
    nonTrivial              = false;
    return;
  end

  % Convert canonical [salient; distractor] format of cues to a side based
  % representation
  if vr.trialType == 1
    vr.cuePos               = trial.cuePos;
    vr.cueCombo             = trial.cueCombo;
  else
    vr.cuePos               = flip(trial.cuePos);
    vr.cueCombo             = flipud(trial.cueCombo);
  end
  vr.nSalient               = trial.nSalient;
  vr.nDistract              = trial.nDistract;
  vr.trialID                = trial.index;

  % Special case for nontrivial experiments -- only count trials with
  % nontrivial cue distributions for performance display
  nonTrivial                = isinf(vr.cueProbability)  ...
                           || (vr.nDistract >  0)       ...
                            ;

  % Initialize times at which cues were turned on
  cueDisplacement           = zeros(numel(vr.cuePos), 1, vr.nCueSlots);
  for iSide = 1:numel(vr.cuePos)
    cueDisplacement(iSide,:,1:numel(vr.cuePos{iSide}))  = vr.cuePos{iSide};

    vr.cueOnset{iSide}      = zeros(size(vr.cuePos{iSide}), vr.iterStr);
    vr.cueOffset{iSide}     = zeros(size(vr.cuePos{iSide}), vr.iterStr);
    vr.cueTime{iSide}       = nan(size(vr.cuePos{iSide}));
    vr.cueAppeared{iSide}   = false(size(vr.cuePos{iSide}));
  end

  % Reposition cues according to the drawn positions
  vr.pos_turnCue            = repmat(cueDisplacement, 1, size(vr.vtx_turnCue,2), 1);
  vr.worlds{vr.currentWorld}.surface.vertices(2,vr.vtx_turnCue) ...
                            = vr.template_turnCue(:) + vr.pos_turnCue(:);
end

%%_________________________________________________________________________
% --- Trial and reward configuration
function vr = setupTrials(vr, shaping)
 
  % Sequence of progressively more difficult mazes; see docs for prepareMazes()
  if nargin < 2
    shaping             = vr.exper.userdata.trainee.protocol;
  end
  [mazes, criteria, globalSettings, vr]   ...
                        = shaping(vr);
  vr                    = prepareMazes(vr, mazes, criteria, globalSettings);
  vr.shapingProtocol    = shaping;

  % Precompute maximum number of cue towers given the cue region length and
  % minimum tower separation
  cueMinSeparation      = str2double(vr.exper.variables.cueMinSeparation);
  for iMaze = 1:numel(vr.mazes)
    vr.mazes(iMaze).variable.nCueSlots  = num2str(floor( str2double(vr.mazes(iMaze).variable.lCue)/cueMinSeparation ));
  end
  
  % Number and mixing of trials
  vr.targetNumTrials    = eval(vr.exper.variables.targetNumTrials);
  vr.fracDuplicated     = eval(vr.exper.variables.fracDuplicated);
  vr.trialDuplication   = eval(vr.exper.variables.trialDuplication);
  vr.trialDispersion    = eval(vr.exper.variables.trialDispersion);
  vr.panSessionTrials   = eval(vr.exper.variables.panSessionTrials);
  vr.trialType          = Choice.nil;
  vr.lastDP             = [0 0 0 0];

  % Nominal extents of world
  vr.worldXRange        = eval(vr.exper.variables.worldXRange);
  vr.worldYRange        = eval(vr.exper.variables.worldYRange);

  % Trial violation criteria
  vr.maxTrialDuration   = eval(vr.exper.variables.maxTrialDuration);
  [vr.iterFcn,vr.iterStr] = smallestUIntStorage(vr.maxTrialDuration / RigParameters.minIterationDT);

  % Special case with no animal -- only purpose is to return maze configuration
  hasTrainee            = isfield(vr.exper.userdata, 'trainee');


  %--------------------------------------------------------------------------

  % Sound for aversive stimulus
  vr.punishment         = loadSound('siren_6kHz_12kHz_1s.wav', 1.2, RigParameters.soundAdjustment);

  % Logged variables
  if hasTrainee
    vr.sensorMode       = vr.exper.userdata.trainee.virmenSensor;
    %vr.frictionCoeff    = vr.exper.userdata.trainee.virmenFrictionCoeff;
  end
  
  % variables for easy blocks
  vr.easyBlockFlag = 0;
  vr.updateReward  = 1;

  % Configuration for logging etc.
  cfg.label             = vr.exper.worlds{1}.name(1);
  cfg.versionInfo       = { 'mazeVersion', 'codeVersion' };
  cfg.mazeData          = { 'mazes' };
  cfg.trialData         = { 'trialProb', 'trialType', 'choice', 'trialID'           ...
                          , 'cueCombo', 'cuePos', 'cueOnset', 'cueOffset'           ...
                          , 'iCueEntry', 'iMemEntry', 'iArmEntry', 'excessTravel'   ...
                          , 'laserEpoch', 'laserON', 'iLaserOn', 'iLaserOff'};
  cfg.protocolData      = { 'rewardScale' };
  cfg.blockData         = { 'mazeID', 'mainMazeID', 'motionBlurRange', 'iterStr'    ...
                          , 'shapingProtocol', 'stimulusBank', 'stimulusCommit'     ...
                          , 'stimulusConfig', 'stimulusSet'  , 'laserParams'        ...
                          , 'frozenStimuli'};
  cfg.totalTrials       = vr.targetNumTrials + vr.panSessionTrials;
  cfg.savePerNTrials    = 1;
  cfg.pollInterval      = eval(vr.exper.variables.logInterval);
  cfg.repositoryLog     = '..\..\version.txt';

  if hasTrainee
    cfg.animal          = vr.exper.userdata.trainee;
    cfg.logFile         = vr.exper.userdata.regiment.whichLog(vr.exper.userdata.trainee);
    cfg.sessionIndex    = vr.exper.userdata.trainee.sessionIndex;
  end

  % The following variables are refreshed each time a different maze level is loaded
  vr.experimentVars     = [ vr.stimulusParameters                           ...
                          , { 'cueDuration', 'yCue'                         ...
                            , 'lStart', 'lCue', 'lMemory', 'lArm'           ... for maze length
                            , 'maxExcessTravel'                             ...
                            } ];

  if ~hasTrainee
    return;
  end

  %--------------------------------------------------------------------------


  % Statistics for types of trials and success counts
  vr.protocol           = ChoiceExperimentStats(cfg.animal, cfg.label, cfg.totalTrials, numel(mazes));
  vr.protocol.plot(1 + ~RigParameters.hasDAQ);
  vr.protocol.addDrawMethod(TrainingRegiment.TRIAL_DRAWING);

  vr.protocol.log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');
  vr.protocol.log('    %s : %s, session %d', vr.exper.userdata.trainee.name, datestr(now), vr.exper.userdata.trainee.sessionIndex);
  vr.protocol.log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~');



  % Predetermine warmup and main mazes based on training history
  [vr.mainMazeID, vr.mazeID, vr.warmupIndex, vr.prevPerformance]  ...
                        = getTrainingLevel(vr.mazes, vr.exper.userdata.trainee, vr.protocol, vr.numMazesInProtocol, cfg.animal.autoAdvance);
  vr.motionBlurRange    = vr.exper.userdata.trainee.motionBlurRange;
  if ~isempty(vr.motionBlurRange)
    vr.experimentVars   = [vr.experimentVars, {'cueColor', 'dimCue'}];
  end
  
    % Protocol-specific stimulus trains, some identical across sessions
  if isempty(vr.exper.userdata.trainee.stimulusBank)
    vr.frozenStimuli    = false;
    vr.stimulusBank     = fullfile( parsePath(getfield(functions(shaping), 'file'))  ...
                                  , ['stimulus_trains_' func2str(shaping) '.mat']    ...
                                  );
    vr                  = checkStimulusBank(vr, false);
    
  % Load custom stimulus bank if provided
  else
    vr.frozenStimuli    = true;
    vr.stimulusBank     = vr.exper.userdata.trainee.stimulusBank;
    vr                  = checkStimulusBank(vr, true);
  end
  
  % Logging of experimental data
  if ~vr.experimentEnded
    vr.logger           = ExperimentLog_laser(vr, cfg, vr.protocol, vr.iterFcn(inf));
  end
  
  vr.prevIndices = [0 0 0];

end

%%-------------------------------------------------------------------------
% randomly choose location and whether to stimulate or not
function vr = drawLaserTrials(vr)


if isempty(vr.laser.currPool); vr.laser.currPool = vr.laser.locationPool; end

vr.laser.lsrON = binornd(1,vr.laser.P_on,1); % will laser be ON or OFF?

if vr.laser.lsrON
    % draw epochs randomly (for now I' assuming it actually will be only one kind per session)
    vr.laser.currentEpoch = randi(vr.laser.nEpochs,1);
    
    switch vr.laser.drawMode
        case 'pseudo-random' % draw until all locations have been visited once
             idx = randi(numel(vr.laser.currPool),1);
             vr.laser.pos = vr.laser.currPool(idx);
             vr.laser.currPool(idx) = []; % remove this from the grab-bag
        case 'random'
            vr.laser.pos = randi(vr.laser.nLocations,1);
    end
else
    vr.laser.pos          = 0;
    vr.laser.currentEpoch = 0;
end

vr.laserEpoch = vr.laser.currentEpoch;
vr.laserON    = vr.laser.lsrON;

% Flags for animal's progress through the maze
vr.iLaserOn               = vr.iterFcn(0);
vr.iLaserOff              = vr.iterFcn(0);
  
end

%%-------------------------------------------------------------------------
% decide where laser needs to be 
function vr = lasercontroller(vr)

vr.laser.prevState = vr.laser.currentState;

if ~vr.laser.lsrON || isempty(vr.logger.currentTrial)
    vr.laser.currentState = 0;
else
    idx = find(vr.logger.currentTrial.time>0,1,'last');
    if vr.stateCode == virmenStateCodes.WithinTrial     && ...
            vr.logger.currentTrial.time(idx) >= 5       && ...
            vr.logger.currentTrial.time(idx) < 9.9 % allow 100 ms for ramp down
        vr.laser.currentState = vr.laser.pos;
    else
        vr.laser.currentState = 0;
    end
    
end

% 8-bit code for position
vr.laser.posOut = dec2bin(vr.laser.currentState,8)-'0';

% easy-access iteration stamp for laser
if vr.laser.currentState > 0 && vr.laser.prevState == 0
    vr.iLaserOn     = vr.iterFcn(vr.logger.iterationStamp(vr));
end
if vr.laser.currentState == 0 && vr.laser.prevState > 0
    vr.iLaserOff    = vr.iterFcn(vr.logger.iterationStamp(vr));
end
    
end


%%-------------------------------------------------------------------------
% Receive experiment parameters through TCP/IP from laser/galvo PC
function vr = receiveExptParams(vr)

vr.tcpip.dataOut = 'OK';
vr.tcpip.currParam = [];

done = 0;
while ~done
    vr = TCPIPcomm_laser('receiveString',vr);
    if ~isempty(vr.tcpip.dataIn)
        vr = TCPIPcomm_laser('send',vr); % send handshake
    else
        continue
    end
    switch vr.tcpip.dataIn
        case 'receiveString'
            
            vr = TCPIPcomm_laser('receiveString',vr);
            while isempty(vr.tcpip.dataIn) || numel(vr.tcpip.dataIn) == 1
                vr = TCPIPcomm_laser('receiveString',vr);
            end
            
            if strcmpi(vr.tcpip.dataIn,'param')
                % name of parameter is sent as 2 lines, first says param
                % and 2nd contains the name
                vr = TCPIPcomm_laser('receiveString',vr);
                vr.tcpip.currParam = vr.tcpip.dataIn;
                
            else
                paramVal = vr.tcpip.dataIn; 
                
                if strcmpi(vr.tcpip.currParam,'epoch') % these two are built as cells 
                    if isfield(vr.laser,'epoch')
                        vr.laser.epoch{length(vr.laser.epoch)+1} = paramVal;
                    else
                        vr.laser.epoch{1} = paramVal;
                    end
                else
                    eval(sprintf('vr.laser.%s = ''%s'';',vr.tcpip.currParam,paramVal))
                end
                vr.tcpip.currParam = [];
            end
            vr = TCPIPcomm_laser('send',vr); % handshake
            
        case 'receiveData'

            % first receive size of data array
            vr.tcpip.datasize = 1;
            vr = TCPIPcomm_laser('receiveData',vr);
            vr.tcpip.datasize = vr.tcpip.dataIn;
            vr = TCPIPcomm_laser('send',vr); % handshake
            
            vr = TCPIPcomm_laser('receiveData',vr);
            paramVal = vr.tcpip.dataIn;
            
            if strcmpi(vr.tcpip.currParam,'locationSet') % these two are built as cells
                if isfield(vr.laser,'locationSet')
                    vr.laser.locationSet{length(vr.laser.locationSet)+1} = paramVal';
                else
                    vr.laser.locationSet{1} = paramVal';
                end
            else  
                eval(sprintf('vr.laser.%s = %d;',vr.tcpip.currParam,paramVal))
            end
            vr.tcpip.currParam = [];
            vr = TCPIPcomm_laser('send',vr); % handshake
            
        case 'done'
            done = 1;
            vr = TCPIPcomm_laser('send',vr);
    end

end

vr.laser.nLocations   = length(vr.laser.locationSet);
vr.laser.nEpochs      = length(vr.laser.epoch);
vr.laserParams        = vr.laser; % just for saving, this will not get updated
vr.laser.currentState = 0;
vr.laser.prevState    = 0;
vr.laser.currentEpoch = 0;
vr.laser.locationPool = 1:vr.laser.nLocations;
vr.laser.currPool     = 1:vr.laser.nLocations;
  
end

function vr = lsrPC_DIO(vr)

% send binary codes for galvo position and virmen behavioral state
vr.dataOut(RigParameters.locationChannels+1) = vr.laser.posOut;
vr.dataOut(numel(RigParameters.locationChannels)+1:end) = ...
    dec2bin(vr.stateCode,numel(RigParameters.virmenStateChannels))-'0';
nidaqDOwrite2ports('writeDO',vr.dataOut);

% get copy of laser trigger from laserGalvo PC 
data               = nidaqDIread('readDI');
vr.laser.lsrTrigIn = data(RigParameters.laserTrigChIdx);
end