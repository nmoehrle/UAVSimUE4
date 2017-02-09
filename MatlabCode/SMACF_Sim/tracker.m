function [positions, rects, gt, time] = tracker(padding, kernel, lambda, output_sigma_factor, interp_factor, cell_factor, ...
    features, show_visualization,step,max_frames,save_results)

%TRACKER Kernelized/Dual Correlation Filter (KCF/DCF) tracking.
%   This function implements the pipeline for tracking with the KCF (by
%   choosing a non-linear kernel) and DCF (by choosing a linear kernel).
%
%     PADDING is the additional tracked region, for context, relative to
%      the target size.
%     KERNEL is a struct describing the kernel. The field TYPE must be one
%      of 'gaussian', 'polynomial' or 'linear'. The optional fields SIGMA,
%      POLY_A and POLY_B are the parameters for the Gaussian and Polynomial
%      kernels.
%     OUTPUT_SIGMA_FACTOR is the spatial bandwidth of the regression
%      target, relative to the target size.
%     INTERP_FACTOR is the adaptation rate of the tracker.
%     CELL_FACTOR is a factor that is used to determine the cell size (of
%     pixels per cell) based on image size.
%     FEATURES is a struct describing the used features (see GET_FEATURES).
%     SHOW_VISUALIZATION will show an interactive video if set to true.
%     STEP determines the shape of the distribution for the scale search.
%     MAX_FRAMES sets the maximum number of frames and returns.
%
%   Outputs:
%    POSITIONS is an Nx2 matrix of target positions over time (in the
%     format [rows, columns]).
%    RECTS is an Nx4 matrix of target bounding boxes over time (in the
%     format [rows, columns]).
%    GT is the groundtruth received from the simulator.
%    TIME is the tracker execution time, without image loading/rendering.
%
%  Based on the code by Joao F. Henriques, 2014


bUDP = 1;
init = 0;

%IP Address (for sending data)
host='127.0.0.1';
%Remote port
imgPortRx = 25000; 
bbPortRx = 25001;
bbPortTx = 25002;
%Maximum packet length
packetLength = 100000;
%Timeout in ms
timeout = 500; 

if (save_results)
%Setup image saving
nz	= strcat('%0',num2str(6),'d'); %number of zeros in the name of image
ext = 'jpg';
dateAsStr = datestr(datetime('now'));
result_path = strcat('results/',dateAsStr(8:11),'_',dateAsStr(4:6),'_',dateAsStr(1:2),'_',dateAsStr(13:14),'_',dateAsStr(16:17),'_',dateAsStr(19:20),'/');
mkdir(result_path);
end

%Wait until get Bbox init
%If bUDP=1, images and tracking data are shared through a UDP connection 
if (bUDP)
    while(~init)
        bbString = judp('receive',bbPortRx,packetLength,timeout);
        bbLength = length(bbString);
        if (bbLength >1)
            init_gt = eval( [ '[', bbString', ']' ] );
            init = 1;
            disp('Initialization successful!')
        else
            disp('Waiting for bounding box from simulator...')
        end
        %Receive image
        byteArray = judp('receive',imgPortRx,packetLength,timeout);
        if (length(byteArray) > 1)
            %Decode JPEG
            im = decode_jpeg (byteArray);
        else
            disp('Waiting for image from simulator...');
        end  
    end
%If bUDP=0, images and tracking data will be shared through disk        
else
    while(~init)
        if(exist([video_path 'init_gt.txt'],'file'))
            init_gt = dlmread([video_path 'init_gt.txt']);
            init = 1;
        end
    end
end

pos = [init_gt(2)+floor(init_gt(4)/2) init_gt(1)+floor(init_gt(3)/2)];
target_sz = [init_gt(4) init_gt(3)];

temp = load('w2crs');
w2c = temp.w2crs;
scales = [0.97 0.98 0.99 1 1.01 1.02 1.03];
num_scale = length(scales);
%scale_weights = ones(1,num_scale);
scale_weights = normpdf(linspace(-step,step,num_scale),0,1);
best_scale = 1;

%if the target is large, lower the resolution, we don't need that much
%detail
% resize_image = (sqrt(prod(target_sz)) >= 100);  %diagonal size >= threshold
% if resize_image,
%     pos = floor(pos / 2);
%     target_sz = floor(target_sz / 2);
% end


%window size, taking padding into account
window_sz = floor(target_sz * (1 + padding));

% 	%we could choose a size that is a power of two, for better FFT
% 	%performance. in practice it is slower, due to the larger window size.
% 	window_sz = 2 .^ nextpow2(window_sz);

%Calculate cell size
if (features.gray)
    cell_size = 1;
else
    cell_min = 2;
    cell_max = 8;
    cell_size = min(max(cell_min,ceil((sqrt(prod(window_sz)))./(cell_factor*(1 + padding)))),cell_max);
    disp(['Cell Size: ', num2str(cell_size)]);
end


%create regression labels, gaussian shaped, with a bandwidth
%proportional to target size
output_sigma = sqrt(prod(target_sz)) * output_sigma_factor / cell_size;
yf = fft2(gaussian_shaped_labels(output_sigma, floor(window_sz / cell_size)));

%store pre-computed cosine window
cos_window = hann(size(yf,1)) * hann(size(yf,2))';

%note: variables ending with 'f' are in the Fourier domain.
%Initialize variables
time = 0;  %to calculate FPS
positions = zeros(max_frames, 2);  %to calculate precision
rects = zeros(max_frames, 4);  %to calculate
gt = zeros(max_frames, 4);  %to calculate
motion = [0,0];
size_ver = size(cos_window,1);
size_hor = size(cos_window,2);

lastImage = 0;

for frame = 1:max_frames,
    tic()
    %disp(['Frame: ',num2str(frame)])
    
    %If bUDP=1, images and tracking data are shared through a UDP connection 
    if (bUDP)      
        %Receive message
        byteArray = judp('receive',imgPortRx,packetLength,timeout);
        if (length(byteArray) > 1)
            %Decode JPEG
            im = decode_jpeg (byteArray);
        else
            disp('No image from simulator!');
        end
        bbString = judp('receive',bbPortRx,packetLength,timeout);
        bbLength = length(bbString);
        if (bbLength >1)
            gt(frame,:) = eval( [ '[', bbString', ']' ] );
        else
            disp('No GT from simulator!')
        end
    %If bUDP=0, images and tracking data will be shared through disk    
    else     
        im_load_attempts = 5;
        img_files = dir([video_path '*jpg']);
        if (length(img_files)>lastImage)
            lastImage = length(img_files);
            disp(['Loading Image: ' num2str(lastImage)]);
            dlmwrite([video_path 'wait.txt'],1);
            for im_load_counter = 1:im_load_attempts
                try
                    im = imread([video_path img_files(lastImage).name]);
                    break;
                catch
                    if (im_load_counter < im_load_attempts)
                        fprintf('Loading image %u failed! (Attempt %u).\n', frame,im_load_counter);
                    else
                        fprintf('Last Attempt...\n');
                        im = imread([video_path img_files(lastImage).name]);
                    end
                end
            end
            dlmwrite([video_path 'wait.txt'],0);
        else
            disp('No New Image!');
            continue;
        end
    end

    if (~features.hogcolor)
        if size(im,3) > 1,
            im = rgb2gray(im);
        end
    end
    
%     if resize_image,
%         im = imresize(im, 0.5);
%     end
    imgW = size(im,2);
    imgH = size(im,1);
    
    %tic()
       
    if frame == 1,  %first frame, train with a single image
        %init_gt = dlmread([video_path 'init_gt.txt']);
        pos = [init_gt(2)+floor(init_gt(4)/2) init_gt(1)+floor(init_gt(3)/2)];
        target_sz = [init_gt(4) init_gt(3)];
        %dlmwrite([video_path 'init.txt'],1);
        
        patch = get_subwindow(im, pos, window_sz);
        xf   = fft2(get_features(patch, features, cell_size, cos_window,w2c));
        switch kernel.type
            
            case 'gaussian',
                kf = gaussian_correlation(xf, xf, kernel.sigma);
            case 'polynomial',
                kf = polynomial_correlation(xf, xf, kernel.poly_a, kernel.poly_b);
            case 'linear',
                kf = linear_correlation(xf, xf);
                
        end
        
        alphaf = yf ./ (kf + lambda);   %equation for fast training
        model_alphaf = alphaf;
        model_xf = xf;
        
        %if frame > 1
    else
        if (frame > 2)
            motion = positions(frame-1,:) - positions(frame-2,:);
        end
        pos_est = pos + motion;
        
        %At center position
        %frame, and convert to Fourier domain (its size is unchanged)
        patch = get_subwindow(im,pos,round(window_sz*best_scale));
        if (~features.hogcolor)
            patch = videoResize(patch,window_sz);
        else
            patch = imresize(patch,window_sz,'nearest');
        end
        zf = fft2(get_features(patch, features, cell_size, cos_window,w2c));
        %calculate response of the classifier at all shifts
        switch kernel.type
            case 'gaussian',
                kzf = gaussian_correlation(zf, model_xf, kernel.sigma);
            case 'polynomial',
                kzf = polynomial_correlation(zf, model_xf, kernel.poly_a, kernel.poly_b);
            case 'linear',
                kzf = linear_correlation(zf, model_xf);
        end
        response = real(ifft2(model_alphaf .* kzf)*numel(kzf));  %equation for fast detection
        
        
        %             [best_scale, pos,response] = tracker_multi_KCF(im, pos,kernel,cell_size, ...
        %                 features,window_sz,...
        %                 cos_window,model_xf,model_alphaf,num_scale,scales,scale_weights,w2c);
        
        
        if (0 < pos_est(2) && pos_est(2) < imgW && 0 < pos_est(1) && pos_est(1) < imgH && (pos_est(1) ~= pos(1) || pos_est(2) ~= pos(2)))
            %At estimated position
            %frame, and convert to Fourier domain (its size is unchanged)
            patch = get_subwindow(im,pos_est,round(window_sz*best_scale));
            if (~features.hogcolor)
                patch = videoResize(patch,window_sz);
            else
                patch = imresize(patch,window_sz,'nearest');
            end
            zf = fft2(get_features(patch, features, cell_size, cos_window,w2c));
            %calculate response of the classifier at all shifts
            switch kernel.type
                case 'gaussian',
                    kzf = gaussian_correlation(zf, model_xf, kernel.sigma);
                case 'polynomial',
                    kzf = polynomial_correlation(zf, model_xf, kernel.poly_a, kernel.poly_b);
                case 'linear',
                    kzf = linear_correlation(zf, model_xf);
            end
            response_est = real(ifft2(model_alphaf .* kzf)*numel(kzf));  %equation for fast detection
            
            %             [best_scale_est, pos_est,response_est] = tracker_multi_KCF(im, pos_est,kernel,cell_size, ...
            %                 features,window_sz,...
            %                 cos_window,model_xf,model_alphaf,num_scale,scales,scale_weights,w2c);
            
            %Check which one is better
            if (max(response_est(:)) > max(response(:)))
                response = response_est;
                pos = pos_est;
                %best_scale = best_scale_est;
            end
            
        end
        
        [best_scale, pos,response] = tracker_multi_KCF(im, pos,kernel,cell_size, ...
            features,window_sz,...
            cos_window,model_xf,model_alphaf,num_scale,scales,scale_weights,w2c);
        
        
        if (best_scale <0.3)
            best_scale = 0.3;
        elseif (best_scale>3)
            best_scale =3;
        end
        
        %Update scales
        scales = scales*best_scale/scales(round(end/2));
        
        %target location is at the maximum response. we must take into
        %account the fact that, if the target doesn't move, the peak
        %will appear at the top-left corner, not at the center (this is
        %discussed in the paper). the responses wrap around cyclically.
        [vert_delta, horiz_delta] = find(response == max(response(:)), 1);
        if vert_delta > size_ver / 2,  %wrap around to negative half-space of vertical axis
            vert_delta = vert_delta - size_ver;
        end
        if horiz_delta > size_hor / 2,  %same for horizontal axis
            horiz_delta = horiz_delta - size_hor;
        end
        
        pos = pos + (cell_size * [vert_delta - 1, horiz_delta - 1])*best_scale;
        patch = get_subwindow(im, pos, round(window_sz*best_scale));
        %figure (4), imshow(patch);
        if (~features.hogcolor)
            patch = videoResize(patch,window_sz);
        else
            patch = imresize(patch,window_sz,'nearest');
        end
        
        %training at newly estimated target position
        xf = fft2(get_features(patch, features, cell_size, cos_window,w2c));
        
        %Kernel Ridge Regression, calculate alphas (in Fourier domain)
        switch kernel.type
            case 'gaussian',
                kf = gaussian_correlation(xf, xf, kernel.sigma);
            case 'polynomial',
                kf = polynomial_correlation(xf, xf, kernel.poly_a, kernel.poly_b);
            case 'linear',
                kf = linear_correlation(xf, xf);
        end
        alphaf = yf ./ (kf + lambda);   %equation for fast training
        %interpolate model
        model_alphaf = (1 - interp_factor) * model_alphaf + interp_factor * alphaf;
        model_xf = (1 - interp_factor) * model_xf + interp_factor * xf;
    end     
  
    %save position and timing
    %positions(lastImage,:) = pos;
    positions(frame,:) = pos;
    %time = time + toc();
        
    box = [pos([2,1]) - target_sz([2,1])*best_scale/2, target_sz([2,1])*best_scale];
    %rect_results(lastImage,:)=box;
    rects(frame,:)=box;
    
    %disp('prediction: ')
    %disp(rects(frame,:))
    %disp('groundtruth: ')
    %disp(gt(frame,:))
    
    if (save_results)
    filename = strcat(result_path,sprintf(nz,frame),'.',ext);       
    imwrite(im, filename); 
    end
 
    %box_str = strjoin(arrayfun(@(x) num2str(x),box,'UniformOutput',false),',');
    box_str = sprintf('%.1f,', box);
    box_str = box_str(1:end-1);

    %Pass bounding box to simulator
    if (bUDP)
        %Send bounding box
        judp('send',bbPortTx,host,int8(box_str));
    else
    for im_load_counter = 1:im_load_attempts
        try
            dlmwrite([video_path 'gt.txt'],box);
            break;
        catch
            if (im_load_counter < im_load_attempts)
                fprintf('Writing gt failed! (Attempt %u).\n', im_load_counter);
            else
                fprintf('Last Attempt...\n');
                   dlmwrite([video_path 'gt.txt'],box);
            end
        end
    end   
    end

    %visualization
%     if show_visualization,
%         stop = update_visualization(frame, box);
%         if stop, break, end  %user pressed Esc, stop early
%         
%         drawnow
%         % 			pause(0.05)  %uncomment to run slower
%     end

if show_visualization,
imshow(im);
rectangle('Position', box, 'EdgeColor', 'g', 'LineWidth', 3);
pause(0.01)
clf
end

time = time + toc();
end

if (save_results)
dlmwrite(strcat(result_path, 'groundtruth.txt'),gt);
dlmwrite(strcat(result_path, 'tracker_bb.txt'), round(rects));
end
% if resize_image,
%     positions = positions * 2;
%     rect_results = rect_results*2;
% end
end
