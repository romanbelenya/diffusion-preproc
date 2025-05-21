#! /bin/bash
set -e

### Inputs

SRC=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

usage() {
    cat <<EOF
Usage: $(basename $0) [-a <AP basename>] [-p <PA basename>] [-o <output directory>] [-n <threads>] [-g <phantom>] [-e <path to Python exec>] [-s <stage number>]
EOF
}

help() {
    cat <<EOF
Usage: $(basename $0) [-a <AP basename>] [-p <PA basename>] [-o <output directory>] [-n <threads>] [-g <phantom>] [-e <path to Python exec>] [-s <stage number>]

-a: basename of the series acquired in anterior to posterior phase-encoding direction (without .json or .nii.gz)
-p: basename of the series acquired in posterior to anterior phase-encoding direction
-o: path to the output directory
-n: number of threads. Optional. Default=5
-g: this is a phantom scan. Runs 3dAutomask for "brain" extraction instead of mri_synthstrip
-e: path to Python executable. Default=standard python
-s: stage number after which the script will stop. Optional. 1=preparing and file checks, 2=preprocessing, 3=topup, 4=eddy, 5=dti. Default=5
EOF
}

while getopts a:p:o:n:g:e:s:h opt; do
    case "$opt" in
        a)
        AP_BASENAME=$OPTARG
        ;;
        p)
        PA_BASENAME=$OPTARG
        ;;
        o)
        OUT=$OPTARG
        ;;
        n)
        NTHR=$OPTARG
        ;;
        g)
        PHANTOM=$OPTARG
        ;;
        e)
        PYTHON=$OPTARG
        ;;
        s)
        STAGE=$OPTARG
        ;;
        h)
        help
        exit 0
        ;;

        :)
        echo "Option requires an argument" >&2 && exit 1;;

        ?)
        echo "Confusing stuff..." >&2 && exit 1;;
    esac
done
shift "$(( OPTIND - 1 ))"



if [[ -z $NTHR ]]; then
    NTHR=5
fi

if [[ -z $PHANTOM ]]; then
    PHANTOM=0
fi

if [[ -z $PYTHON ]]; then
    PYTHON=$(which python)
fi
if [[ -z $STAGE ]]; then
    STAGE=5
fi

export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$NTHR





echo
echo "================ PREPROCESSING... ================"
echo

echo "AP_BASENAME: ${AP_BASENAME}"
echo "PA_BASENAME: ${PA_BASENAME}"
echo "OUT:         ${OUT}"
echo "NTHR:        ${NTHR}"
echo "PHANTOM:     ${PHANTOM}"
echo "PYTHON:      ${PYTHON}"
echo "-----------------------------\n\n"

####################################################################################
################### STAGE 1 - prepare files and check everything ###################
####################################################################################
# Check if all files are there
basenames=( $AP_BASENAME $PA_BASENAME )
exts=( ".nii.gz" ".bvec" ".bval" ".json" )
for basename in ${basenames[@]}; do
    for ext in ${exts[@]}; do
        file="${basename}${ext}"
        [ ! -f $file ] && echo "$file does not exist!" && exit 1
    done
done

### Check if the scans parameters match
echo
echo "================ checking files... ================"
echo

$PYTHON $SRC/compare-paap.py -a $AP_BASENAME -p $PA_BASENAME

echo
echo start script?
select answer in Yes No; do
    case $answer in
        Yes)
            echo "let's go!" && break;;
        No)
            exit 1;;
    esac
done
echo

start_time=$(date)

### Output directory
if [[ -d $OUT ]]; then
    echo "not creating ${OUT}... already exists"
else
    mkdir -p $OUT && chmod 777 $OUT
fi

### Adjust the small difference between the affines
echo
echo "================ adjusting affines... ================"
echo

$PYTHON $SRC/fix-affine-inaccuracy.py -a $AP_BASENAME -p $PA_BASENAME


### Concatenate the two phase-encoding directions
echo
echo "================ preparing files... ================"
echo

bvals="${OUT}/bvals"
if [[ -f $bvals ]]; then
    echo "skipping... ${bvals} already exists"
else
    paste -d " " "${AP_BASENAME}.bval" "${PA_BASENAME}".bval > $bvals
fi

# Tweak the bvals
bvals_rounded="${OUT}/bvals_rounded"
cp $bvals $bvals_rounded
sed -i -e "s/\<2050\>/2000/g" -e "s/\<1950\>/2000/g" -e "s/\<1050\>/1000/g" -e "s/\<950\>/1000/g" -e "s/\<50\>/0/g" $bvals_rounded

bvecs="${OUT}/bvecs"
if [[ -f $bvecs ]]; then
    echo "skipping... ${bvecs} already exists"
else
    paste -d " " "${AP_BASENAME}.bvec" "${PA_BASENAME}".bvec > $bvecs
fi

dwi="${OUT}/dwi.nii.gz"
if [[ -f $dwi ]]; then
    echo "skipping... ${dwi} already exists"
else
    fslmerge -t $dwi "${AP_BASENAME}" "${PA_BASENAME}"
fi

if [[ $STAGE -eq 1 ]]; then
    echo -e "\n\nDONE after stage $STAGE"
    echo "==================================="
    echo "Started: $start_time"
    echo "Finished: $(date)"
    exit 0
fi


####################################################################################
################### STAGE 2 - preprocessing ###################
####################################################################################
echo
echo "================ preprocessing dwi... ================"
echo

dwi_den="${OUT}/dwi_den.nii.gz"
if [[ -f $dwi_den ]]; then
    echo "skipping... ${dwi_den} already exists"
else
    dwidenoise $dwi $dwi_den -nthreads $NTHR
fi

dwi_den_unr="${OUT}/dwi_den_unr.nii.gz"
if [[ -f $dwi_den_unr ]]; then
    echo "skipping... ${dwi_den_unr} already exists"
else
    mrdegibbs $dwi_den $dwi_den_unr -nthreads $NTHR -axes 1,0
fi

if [[ $STAGE -eq 2 ]]; then
    echo -e "\n\nDONE after stage $STAGE"
    echo "==================================="
    echo "Started: $start_time"
    echo "Finished: $(date)"
    exit 0
fi

####################################################################################
################### STAGE 3 - topup ###################
####################################################################################
echo
echo "================ running topup... ================"
echo

topup_dir="${OUT}/topup"
if [[ -d $topup_dir ]]; then
    echo "not creating ${topup_dir} - already exists"
else
    mkdir $topup_dir
fi

b0="${topup_dir}/b0.nii.gz"
if [[ -f $b0 ]]; then
    echo "skipping... ${b0} already exists"
else
    dwiextract $dwi_den_unr $b0 -bzero -fslgrad $bvecs $bvals -config BZeroThreshold 60
fi

# Make acqparams file
acqparams="${topup_dir}/acqparams.txt"
if [[ -f $acqparams ]]; then
    echo "skipping... ${acqparams} already exists"
else

    touch $acqparams
    basenames=( $AP_BASENAME $PA_BASENAME )
    for basename in "${basenames[@]}"; do

        readout_time=$( jq .TotalReadoutTime "${basename}.json" ) #0.16236 # 0.028
        pe_dir=$( jq .PhaseEncodingDirection "${basename}.json" )
        if [[ $pe_dir == "\"j\"" ]]; then pe_dir=1; else pe_dir=-1; fi

        for b in $( cat "${basename}.bval" ); do
            if [ $b -le 100 ]; then
                echo "0 ${pe_dir} 0 ${readout_time}" >> $acqparams
            fi
        done
    done

fi

echo "acqparams file:"
cat $acqparams
echo

topup_basename="${topup_dir}/b0_topup"
topup_img="${topup_dir}/b0_topup_img.nii.gz"
topup_field="${topup_dir}/b0_topup_field.nii.gz"
if [[ -f $topup_img ]]; then
    echo "skipping... ${topup_img} already exists"
else

    time topup \
        --imain=$b0 \
        --datain=$acqparams \
        --config=b02b0.cnf \
        --out=$topup_basename \
        --iout=$topup_img \
        --fout=$topup_field \
        --logout="${topup_dir}/topup.log" \
        --nthr=$NTHR \
        --scale=1 \
        --verbose
fi

### Make binary brain mask
echo
echo "================ making brain mask... ================"
echo

b0_topup_img_mean="${topup_dir}/b0_topup_img_mean.nii.gz"
if [[ -f $b0_topup_img_mean ]]; then
    echo "skipping... ${b0_topup_img_mean} already exists"
else
    fslmaths $topup_img -Tmean $b0_topup_img_mean
fi

b0_topup_img_mean_bcor="${topup_dir}/b0_topup_img_mean_bcor.nii.gz"
if [[ -f $b0_topup_img_mean_bcor ]]; then
    echo "skipping... ${b0_topup_img_mean_bcor} already exists"
else
    N4BiasFieldCorrection -d 3 -i $b0_topup_img_mean -o $b0_topup_img_mean_bcor -v
fi

brainmask="${topup_dir}/b0_topup_img_mean_bcor_brainmask.nii.gz"
if [[ -f $brainmask ]]; then
    echo "skipping... ${brainmask} already exists"
else
    if [[ $PHANTOM != 0 ]]; then
        echo "running brain extraction for phantom"
        3dAutomask -prefix $brainmask $b0_topup_img_mean_bcor
    else
        mri_synthstrip -i $b0_topup_img_mean_bcor -m $brainmask
    fi
fi

if [[ $STAGE -eq 3 ]]; then
    echo -e "\n\nDONE after stage $STAGE"
    echo "==================================="
    echo "Started: $start_time"
    echo "Finished: $(date)"
    exit 0
fi

####################################################################################
################### STAGE 4 - eddy ###################
####################################################################################
echo
echo "================ running eddy... ================"
echo

eddy_dir="${OUT}/eddy"
if [[ -d $eddy_dir ]]; then
    echo "not creating ${eddy_dir} - already exists"
else
    mkdir $eddy_dir
fi

# Create index file
index="${eddy_dir}/index.txt"
if [[ -f $index ]]; then
    echo "skipping... ${index} already exists"
else
    touch $index
    i=0
    for b in $(cat $bvals); do
        if [ $b = 0 ]; then i=$(( $i+1 )); fi;
        echo $i >> $index;
    done
fi

# Create slice order file
slices="${eddy_dir}/slice-order.txt"
$PYTHON $SRC/mb-slice-order.py -s "${AP_BASENAME}.json" -o $slices

eddy_basename="${eddy_dir}/eddy"
if [[ -f "${eddy_basename}.nii.gz" ]]; then
    echo "skipping... ${eddy_basename} already exists"
else
    time eddy_cuda10.2 \
        --imain=$dwi_den_unr \
        --mask=$brainmask \
        --index=$index \
        --acqp=$acqparams \
        --topup=$topup_basename \
        --bvecs=$bvecs \
        --bvals=$bvals_rounded \
        --out=$eddy_basename \
        --data_is_shelled \
        --flm=quadratic \
        --interp=spline \
        --lsr_lambda=0.1 \
        --nvoxhp=10000 \
        --ff=10 \
        --repol \
        --ol_type=both \
        --mporder=6 \
        --s2v_niter=10 \
        --s2v_lambda=1 \
        --s2v_interp=trilinear \
        --slspec=$slices \
        --estimate_move_by_susceptibility \
        --cnr_maps \
        --very_verbose \
        --resamp=lsr 

        # here, rename the resampled output as eddy_lsr.nii.gz and combine the resampled eddy file twice 
        eddy_lsr="${eddy_basename}_lsr.nii.gz"
        echo "moving ${eddy_basename}.nii.gz to $eddy_lsr and combining $eddy_lsr twice to ${eddy_basename}.nii.gz..."
        mv "${eddy_basename}.nii.gz" $eddy_lsr
        fslmerge -t "${eddy_basename}.nii.gz" $eddy_lsr $eddy_lsr
fi


####################################################################################
################### STAGE 4¾ - bias field correction ###################
####################################################################################
echo
echo "================ Correcting bias... ================"
echo

dwi_preproc="${eddy_basename}_lsr.nii.gz"
dwi_preproc_bcor="${dwi_preproc%.nii.gz}_bcor.nii.gz"
bias="${dwi_preproc%.nii.gz}_bias.nii.gz"

if [[ -f "$dwi_preproc_bcor" ]]; then
    echo "skipping... ${dwi_preproc_bcor} already exists"
else
    N4BiasFieldCorrection \
        --image-dimensionality 4 \
        --input-image $dwi_preproc \
        --output [ $dwi_preproc_bcor,$bias ] \
        --rescale-intensities \
        --verbose
        # --mask-image $brainmask \
fi

### Eddy quality check
echo
echo "================ Running eddy qc... ================"
echo

qc_dir="${OUT}/eddyqc"
if [[ -d $qc_dir ]]; then
    echo "skipping... ${qc_dir} - already exists"
else
    echo "Running the quality check on twice the resampled data"

    bvecs_rot="${eddy_basename}.eddy_rotated_bvecs"

    eddy_quad \
        $eddy_basename \
        --eddyIdx=$index \
        --eddyParams=$acqparams \
        --mask=$brainmask \
        --bvals=$bvals_rounded \
        --bvecs=$bvecs_rot \
        --field=$topup_field \
        --slspec=$slices \
        --output=$qc_dir \
        --verbose
fi

if [[ $STAGE -eq 4 ]]; then
    echo -e "\n\nDONE after stage $STAGE"
    echo "==================================="
    echo "Started: $start_time"
    echo "Finished: $(date)"
    exit 0
fi

####################################################################################
################### STAGE 5 - dti ###################
####################################################################################
echo
echo "================ Running dti... ================"
echo

dti_dir="${OUT}/dti"
mkdir $dti_dir

dti_basename="${dti_dir}/dti"
dwi_preproc="${eddy_basename}_lsr_bcor.nii.gz"
bvecs_lsr="${eddy_basename}.eddy_rotated_bvecs_for_SLR"
bvals_lsr="${AP_BASENAME}.bval" # only from the first part

time dtifit \
    --data=$dwi_preproc \
    --mask=$brainmask \
    --bvecs=$bvecs_lsr \
    --bvals=$bvals_lsr \
    --out=$dti_basename \
    --save_tensor \
    --verbose

# make a nice colour image for itksnap
tensor="${dti_basename}_tensor.nii.gz"
tensor_colour="${tensor%.nii.gz}_colour.nii.gz"
ImageMath 3 $tensor_colour 4DTensorTo3DTensor $tensor
ImageMath 3 $tensor_colour TensorColor $tensor_colour

echo -e "\n\nDONE WITH ALL STAGES!"
echo "==================================="
echo "Started: $start_time"
echo "Finished: $(date)"
