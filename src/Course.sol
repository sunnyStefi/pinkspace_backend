//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.18;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @notice This contract govern the creation, transfer and management of certificates.
 */
contract Course is ERC1155, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant EVALUATOR = keccak256("EVALUATOR");
    bytes32 public constant STUDENT = keccak256("STUDENT");

    event Courses_CoursesCreated(uint256 indexed courseId);
    event Courses_CoursesRemoved(uint256 indexed courseId);
    event Courses_EvaluationCompleted(uint256 indexed courseId, address indexed student, uint256 indexed mark);
    event Courses_EvaluatorSetUp(address indexed evaluator);
    event RoleGranted(bytes32 indexed role, address indexed user);

    error Courses_TokenCannotBeTransferedOnlyBurned();
    error Course_IllegalMark(uint256 mark);
    error Courses_NoCourseIsRegisteredForTheUser(address user);
    error Courses_CourseNotRegisteredForTheUser(uint256 courseId, address student);
    error Courses_WithdrawalFailed();
    error Courses_SetCoursesUris_ParamsLengthDoNotMatch();
    error Course_BuyCourse_NotEnoughEthToBuyCourse(uint256 fee, uint256 value);
    error Course_EvaluatorAlreadyAssignedForThisCourse(address evaluator);
    error Course_TooManyEvaluatorsForThisCourse(uint256 maxEvaluatorsAmount);
    error Course_setMaxEvaluatorsAmountCannotBeZero(uint256 newAmount);
    error Course_EvaluatorNotAssignedToCourse(uint256 course, address evaluator);
    error Course_CourseIdDoesNotExist(uint256 courseId);
    error Course_EvaluatorNotAssignedForThisCourse(address evaluator);

    uint256 public constant BASE_COURSE_FEE = 0.01 ether;
    string public constant JSON = ".json";
    string public constant ID_JSON = "/{id}.json";
    string public constant PROTOCOL = "https://ipfs.io/ipfs/";
    string public constant URI_PINATA = "QmZeczzyz6ow8vNJrP7jBnZPdF7CQYrcUjqQZrgXC6hXMF";

    uint256 private s_coursesTypeCounter;
    uint256 private s_maxEvaluatorsAmount = 5;

    mapping(uint256 => uint256) private s_courseToFee;
    mapping(uint256 => EnumerableSet.AddressSet) private s_courseToEvaluators;
    mapping(uint256 => uint256) private s_createdPlacesToCounter;
    mapping(uint256 => uint256) private s_purchasedPlacesToCounter;
    mapping(uint256 => uint256) private s_courseToPassedUsers;
    mapping(uint256 => string) private s_uris; // each course has an uri that points to its metadata
    mapping(uint256 => address) private s_courseToCreator;
    mapping(uint256 => address[]) private s_courseToEnrolledStudents;
    mapping(address => uint256[]) private s_userToCourses;
    mapping(uint256 => EvaluatedStudent[]) private s_courseToEvaluatedStudents;

    struct EvaluatedStudent {
        uint256 mark;
        uint256 date;
        address student;
        address evaluator;
    }

    modifier validateMark(uint256 mark) {
        if (mark < 1 || mark > 10) revert Course_IllegalMark(mark);
        _;
    }

    modifier onlyIfCourseIdExists(uint256 courseId) {
        if (s_courseToCreator[courseId] == address(0)) {
            revert Course_CourseIdDoesNotExist(courseId);
        }
        _;
    }

    modifier onlyAssignedEvaluator(uint256 courseId, address evaluator) {
        if (!s_courseToEvaluators[courseId].contains(evaluator)) {
            revert Course_EvaluatorNotAssignedToCourse(courseId, evaluator);
        }
        _;
    }

    constructor() ERC1155(string.concat(PROTOCOL, URI_PINATA, ID_JSON)) {
        //todo role admin transfer
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(EVALUATOR, ADMIN);
        _setRoleAdmin(STUDENT, ADMIN);

        _grantRole(ADMIN, _msgSender());
        _grantRole(ADMIN, address(this));

        s_coursesTypeCounter = 0;
    }

    function createCourses(
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data,
        string[] memory uris,
        uint256[] memory fees
    ) public onlyRole(ADMIN) returns (uint256) {
        s_coursesTypeCounter += values.length;
        setData(ids, values, uris, fees);
        _mintBatch(_msgSender(), ids, values, data);
        setApprovalForAll(_msgSender(), true);
        emit Courses_CoursesCreated(s_coursesTypeCounter);
        return ids.length;
    }

    function setUpEvaluator(address evaluator, uint256 courseId)
        public
        onlyRole(ADMIN)
        onlyIfCourseIdExists(courseId)
    {
        if (s_courseToEvaluators[courseId].contains(evaluator)) {
            revert Course_EvaluatorAlreadyAssignedForThisCourse(evaluator);
        }
        //EnumerableSet uses 0 as a sentinel value -> - 1 to the desired length
        if (s_courseToEvaluators[courseId].length() > (s_maxEvaluatorsAmount - 1)) {
            revert Course_TooManyEvaluatorsForThisCourse(s_maxEvaluatorsAmount);
        }
        s_courseToEvaluators[courseId].add(evaluator);
        grantRole(EVALUATOR, evaluator);
        emit Courses_EvaluatorSetUp(evaluator);
    }

    function removeEvaluator(address evaluator, uint256 courseId)
        public
        onlyRole(ADMIN)
        onlyIfCourseIdExists(courseId)
    {
        if (!s_courseToEvaluators[courseId].contains(evaluator)) {
            revert Course_EvaluatorNotAssignedForThisCourse(evaluator);
        }
        s_courseToEvaluators[courseId].remove(evaluator);
        grantRole(EVALUATOR, evaluator);
    }

    function removePlaces(
        uint256[] memory ids,
        uint256[] memory values //remove from
    ) public onlyRole(ADMIN) {
        updateData(ids, values);
        _burnBatch(_msgSender(), ids, values);
        emit Courses_CoursesRemoved(values.length);
    }

    function removeFailedStudentPlaces(
        address from,
        uint256 id,
        uint256 value //remove from
    ) public onlyRole(ADMIN) returns (uint256) {
        //check if the student is really failed
        s_createdPlacesToCounter[id] -= 1;
        _burn(from, id, value);
        emit Courses_CoursesRemoved(value);
        return s_createdPlacesToCounter[id] -= 1;
    }

    function removePlaces(
        address from,
        uint256 id,
        uint256 value //remove from
    ) public onlyRole(ADMIN) returns (uint256) {
        s_createdPlacesToCounter[id] -= 1;
        _burn(from, id, value);
        emit Courses_CoursesRemoved(value);
    }

    function buyPlace(uint256 courseId) public payable returns (bool) {
        //todo exceptions do not add replicated courses
        if (msg.value < s_courseToFee[courseId]) {
            revert Course_BuyCourse_NotEnoughEthToBuyCourse(s_courseToFee[courseId], msg.value);
        }
        s_userToCourses[_msgSender()].push(courseId);
        s_purchasedPlacesToCounter[courseId] += 1;
        s_courseToEnrolledStudents[courseId].push(_msgSender());
    }
    //todo return bool even above

    function transferPlaceNFT(address student, uint256 courseId) public onlyRole(ADMIN) returns (bool) {
        //this can be initialized only by the owner of the NFT --> cannot put inside buycourse
        safeTransferFrom(s_courseToCreator[courseId], student, courseId, 1, "0x");
    }

    function evaluate(uint256 courseId, address student, uint256 mark)
        public
        onlyRole(EVALUATOR)
        validateMark(mark)
        onlyAssignedEvaluator(courseId, _msgSender())
        returns (bool)
    {
        //TODO evaluated only if it has NFT!
        //TODO validate the course for the student
        //TODO do not evaluate 2 times for each course-student

        uint256[] memory user_courses = s_userToCourses[student];
        bool valid_match = false;
        if (user_courses.length == 0) revert Courses_NoCourseIsRegisteredForTheUser(student);
        uint256 i = 0;
        while (i < user_courses.length) {
            if (user_courses[i] == courseId) {
                s_courseToEvaluatedStudents[i].push(EvaluatedStudent(mark, block.timestamp, student, _msgSender()));
                valid_match = true;
                break;
            }
            i++;
        }
        if (mark > 6) s_courseToPassedUsers[courseId] += 1;
        if (!valid_match) revert Courses_CourseNotRegisteredForTheUser(courseId, student);
        emit Courses_EvaluationCompleted(courseId, student, mark);
        return valid_match;
    }

    //Only Admin can approve whom is transferred to
    function setApprovalForAll(address operator, bool approved) public override onlyRole(ADMIN) {
        super.setApprovalForAll(operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data)
        public
        override
        onlyRole(ADMIN)
    {
        super.safeTransferFrom(from, to, id, value, data);
    }

    function makeCertificates(uint256 courseId, string memory certificateUri) public onlyRole(ADMIN) {
        //todo all evaluated = enrolled
        //Burns for the not promoted students
        uint256 evaluatedStudents = s_courseToEvaluatedStudents[courseId].length;
        uint256 notSoldCourses = s_createdPlacesToCounter[courseId] - s_purchasedPlacesToCounter[courseId];
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = courseId;
        values[0] = notSoldCourses;
        removePlaces(ids, values);

        for (uint256 i = 0; i < evaluatedStudents; i++) {
            if (s_courseToEvaluatedStudents[courseId][i].mark < 6) {
                removeFailedStudentPlaces(s_courseToEvaluatedStudents[courseId][i].student, courseId, 1);
            } else {
                setCertificateUri(courseId, certificateUri);
            }
        }
    }

    function withdraw() public payable onlyRole(ADMIN) {
        (bool succ,) = payable(_msgSender()).call{value: address(this).balance}(""); //change owner
        if (!succ) revert Courses_WithdrawalFailed(); //todo transfer ownership
    }

    function uri(uint256 _tokenid) public view override returns (string memory) {
        return s_uris[_tokenid];
    }

    function setData(uint256[] memory courseIds, uint256[] memory values, string[] memory uri, uint256[] memory fees)
        private
        onlyRole(ADMIN)
    {
        //check same length
        // todo make another Struct with uri, fees, owner
        if (courseIds.length != uri.length) revert Courses_SetCoursesUris_ParamsLengthDoNotMatch(); //add  fees
        for (uint256 i = 0; i < courseIds.length; i++) {
            uint256 courseId = courseIds[i];
            s_createdPlacesToCounter[courseId] += values[i];
            s_uris[courseId] = uri[i];
            s_courseToFee[courseId] = fees[i];
            s_courseToCreator[courseId] = _msgSender();
        }
    }

    function updateData(uint256[] memory courseId, uint256[] memory values) public onlyRole(ADMIN) {
        //check same length
        // todo make another Struct with uri, fees, owner
        if (courseId.length != values.length) revert Courses_SetCoursesUris_ParamsLengthDoNotMatch(); //add  fees
        for (uint256 i = 0; i < values.length; i++) {
            s_createdPlacesToCounter[courseId[i]] -= values[i];
        }
    }

    function setCertificateUri(uint256 courseId, string memory uri) public onlyRole(ADMIN) {
        s_uris[courseId] = uri;
    }

    function getCourseUri(uint256 courseId) public returns (string memory) {
        return s_uris[0];
    }

    function contractURI() public pure returns (string memory) {
        return string.concat(PROTOCOL, URI_PINATA, "/collection.json");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function getEvaluators(uint256 courseId)
        public
        view
        onlyIfCourseIdExists(courseId)
        returns (address[] memory evaluators)
    {
        return s_courseToEvaluators[courseId].values();
    }

    function getCourseToEnrolledStudents(uint256 courseId) public view returns (address[] memory) {
        return s_courseToEnrolledStudents[courseId];
    }

    function getCoursesPerUser(address user) public view returns (uint256[] memory) {
        return s_userToCourses[user];
    }

    function getCourseToEvaluateStudents(uint256 courseId) public view returns (EvaluatedStudent[] memory) {
        return s_courseToEvaluatedStudents[courseId];
    }

    function getPromotedStudents(uint256 courseId)
        public
        view
        returns (address[] memory, address[] memory, uint256, uint256)
    {
        uint256 countPromoted = 0;
        uint256 countFailed = 0;
        uint256 evaluatedStudentsPerCourse = s_courseToEvaluatedStudents[courseId].length;
        address[] memory promoted = new address[](evaluatedStudentsPerCourse);
        address[] memory failed = new address[](evaluatedStudentsPerCourse);
        for (uint256 i = 0; i < evaluatedStudentsPerCourse; i++) {
            if (s_courseToEvaluatedStudents[courseId][i].mark >= 6) {
                promoted[countPromoted] = s_courseToEvaluatedStudents[courseId][i].student;
                countPromoted++;
            }
            if (s_courseToEvaluatedStudents[courseId][i].mark < 6) {
                failed[countFailed] = s_courseToEvaluatedStudents[courseId][i].student;
                countFailed++;
            }
        }

        assembly {
            mstore(promoted, countPromoted)
            mstore(failed, countFailed)
        }

        return (promoted, failed, countPromoted, countFailed);
    }

    function setUri(string memory uri) public onlyRole(ADMIN) {
        _setURI(uri);
    }

    function _setURI(string memory newuri) internal override {
        super._setURI(newuri);
    }

    function getCoursesCounter() public view returns (uint256) {
        return s_coursesTypeCounter;
    }

    function getCreatedPlacesCounter(uint256 courseId) public view returns (uint256) {
        return s_createdPlacesToCounter[courseId];
    }

    function getPurchasedPlacesCounter(uint256 courseId) public view returns (uint256) {
        return s_purchasedPlacesToCounter[courseId];
    }

    function getEvaluatedStudents(uint256 courseId) public view returns (uint256) {
        return s_courseToEvaluatedStudents[courseId].length;
    }

    function setMaxEvaluatorsAmount(uint256 newAmount) public {
        if (newAmount == 0) revert Course_setMaxEvaluatorsAmountCannotBeZero(newAmount);
        s_maxEvaluatorsAmount = newAmount;
    }

    function getMaxEvaluatorsPerCourse() public view returns (uint256) {
        return s_maxEvaluatorsAmount;
    }

    function getEvaluatorsPerCourse(uint256 courseId) public view returns (uint256) {
        return s_courseToEvaluators[courseId].length();
    }

    function getCourseCreator(uint256 courseId) public view returns (address) {
        return s_courseToCreator[courseId];
    }
}
